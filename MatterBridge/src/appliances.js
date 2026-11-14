import { Worker } from '@matter/main';
import { WindowCoveringDevice } from '@matter/main/devices/window-covering';
import { ThermostatDevice } from '@matter/main/devices/thermostat';
import { WindowCoveringServer } from '@matter/main/behaviors/window-covering';
import { ThermostatServer } from '@matter/main/behaviors/thermostat';

const Covering = WindowCoveringServer.with('Lift', 'PositionAwareLift');
const Heating = ThermostatServer.with('Heating');
export const applianceTypes = {
  windowCovering: WindowCoveringDevice.with(Covering),
  thermostat: ThermostatDevice.with(Heating),
};

// Driver position is percent open; Matter is hundredths of percent closed.
const closedPosition = value => Number.isInteger(value) && value >= 0 && value <= 100 ? (100 - value) * 100 : null;

export function applianceState(d) {
  const a = d.attributes ?? {};
  if (d.kind === 'windowCovering') {
    const position = closedPosition(a.position);
    const target = closedPosition(a.targetPosition ?? a.position);
    const movement = Number.isInteger(a.movement) && a.movement >= 0 && a.movement <= 2 ? a.movement : 0;
    return { windowCovering: {
      type: 0, endProductType: 0,
      configStatus: { operational: d.reachable, onlineReserved: false, liftMovementReversed: false,
        liftPositionAware: true, tiltPositionAware: false, liftEncoderControlled: true, tiltEncoderControlled: false },
      currentPositionLiftPercent100ths: position,
      currentPositionLiftPercentage: position === null ? null : Math.round(position / 100),
      targetPositionLiftPercent100ths: target,
      operationalStatus: { global: movement, lift: movement, tilt: 0 },
    } };
  }
  const minimum = a.targetTemperatureMin;
  const maximum = a.targetTemperatureMax;
  return { thermostat: {
    localTemperature: Number.isInteger(a.temperature) ? a.temperature : null,
    occupiedHeatingSetpoint: a.targetTemperature ?? minimum,
    absMinHeatSetpointLimit: minimum, absMaxHeatSetpointLimit: maximum,
    minHeatSetpointLimit: minimum, maxHeatSetpointLimit: maximum,
    controlSequenceOfOperation: 2, systemMode: d.on ? 4 : 0,
  } };
}

export function applianceControls(device, write, syncing) {
  if (device.kind === 'windowCovering') {
    let sequence = 0;
    class DeviceCovering extends Covering {
      initialize() {
        this.internal.disableOperationalModeHandling = true;
        super.initialize();
        this.reactTo(this.events.mode$Changing, value => {
          if (value.motorDirectionReversed || value.calibrationMode || value.maintenanceMode) {
            throw new Error('Motor configuration is managed by its native driver');
          }
        });
      }
      upOrOpen() { return this.begin('open', true, 100); }
      downOrClose() { return this.begin('close', true, 0); }
      stopMotion() { return this.begin('stop', true); }
      goToLiftPercentage({ liftPercent100thsValue }) {
        if (!Number.isInteger(liftPercent100thsValue) || liftPercent100thsValue < 0 || liftPercent100thsValue > 10000) {
          throw new Error('Invalid covering position');
        }
        const position = 100 - Math.round(liftPercent100thsValue / 100);
        return this.begin('position', position, position);
      }
      async begin(property, value, target) {
        // A cache-sync worker may still hold this resource. Acquire asynchronously rather than
        // failing a new command on a synchronous lock; release it before waiting for native motion.
        await this.context.transaction.begin();
        await this.context.transaction.addResources(this);
        if (!this.endpoint.state.bridgedDeviceBasicInformation.reachable) throw new Error('Device offline');
        const current = ++sequence, endpoint = this.endpoint;
        if (target !== undefined) this.state.targetPositionLiftPercent100ths = closedPosition(target);
        // A Matter movement command acknowledges acceptance, not completion. Its worker releases the
        // endpoint transaction so Stop can reach the driver's priority lane while readback is pending.
        const done = (async () => {
          try {
            const confirmed = await write(property, value);
            if (current === sequence) await endpoint.set(applianceState(confirmed));
          } catch {
            // Keep actual position intact. The App's cached failure state is delivered by normal sync.
            // An old movement cancelled by Stop must not overwrite the newer command's result.
            if (current === sequence) console.error('Covering command was not confirmed; inspect local diagnostic logs.');
          }
        })();
        this.env.runtime.add(Worker({ name: 'covering command', done, lifetime: this.lifetime }));
      }
    }
    return [DeviceCovering];
  }
  if (device.kind === 'thermostat') {
    class DeviceHeating extends Heating {
      initialize() {
        super.initialize();
        this.reactTo(this.events.occupiedHeatingSetpoint$Changing, this.targetChanging);
        this.reactTo(this.events.systemMode$Changing, this.modeChanging);
      }
      targetChanging(value) {
        if (syncing.has(device.did)) return;
        const a = device.attributes;
        if (!Number.isInteger(value) || value < a.targetTemperatureMin || value > a.targetTemperatureMax ||
            (value - a.targetTemperatureMin) % a.targetTemperatureStep !== 0) throw new Error('Unsupported temperature step');
        this.confirmBeforeCommit('target', async () => {
          const confirmed = await write('targetTemperature', value);
          if (confirmed.attributes.targetTemperature !== value) throw new Error('Temperature was not confirmed');
        });
      }
      modeChanging(value) {
        if (syncing.has(device.did)) return;
        if (value !== 0 && value !== 4) throw new Error('Only Off and Heat are supported');
        this.confirmBeforeCommit('power', () => write('on', value === 4));
      }
      confirmBeforeCommit(key, action) {
        let done = false;
        this.context.transaction.addParticipants({
          toString: () => device.did + ':heating:' + key,
          async preCommit() { if (!done) { done = true; await action(); } return false; },
        });
      }
    }
    return [DeviceHeating];
  }
  return [];
}
