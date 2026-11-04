import { OnOffServer } from '@matter/main/behaviors/on-off';
import { AirPurifierDevice } from '@matter/main/devices/air-purifier';
import { OnOffLightDevice } from '@matter/main/devices/on-off-light';
import { OnOffPlugInUnitDevice } from '@matter/main/devices/on-off-plug-in-unit';
import { DimmableLightDevice } from '@matter/main/devices/dimmable-light';
import { ColorTemperatureLightDevice } from '@matter/main/devices/color-temperature-light';
import { FanDevice } from '@matter/main/devices/fan';
import { TemperatureSensorDevice } from '@matter/main/devices/temperature-sensor';
import { HumiditySensorDevice } from '@matter/main/devices/humidity-sensor';
import { LightSensorDevice } from '@matter/main/devices/light-sensor';
import { ContactSensorDevice } from '@matter/main/devices/contact-sensor';
import { OccupancySensorDevice } from '@matter/main/devices/occupancy-sensor';
import { LevelControlServer } from '@matter/main/behaviors/level-control';
import { ColorControlServer } from '@matter/main/behaviors/color-control';
import { FanControlServer } from '@matter/main/behaviors/fan-control';
import { OccupancySensingServer } from '@matter/main/behaviors/occupancy-sensing';

export const types = { light: OnOffLightDevice, outlet: OnOffPlugInUnitDevice,
  dimmableLight: DimmableLightDevice, colorTemperatureLight: ColorTemperatureLightDevice, fan: FanDevice, airPurifier: AirPurifierDevice,
  temperature: TemperatureSensorDevice, humidity: HumiditySensorDevice, illuminance: LightSensorDevice,
  contact: ContactSensorDevice, occupancy: OccupancySensorDevice };

export function stateFor(d) {
  const a = d.attributes ?? {};
  const v = a[d.kind];
  switch (d.kind) {
    case 'temperature': return { temperatureMeasurement: { measuredValue: Number.isFinite(v) ? v : null } };
    case 'humidity': return { relativeHumidityMeasurement: { measuredValue: Number.isFinite(v) ? v : null } };
    case 'illuminance': return { illuminanceMeasurement: { measuredValue: Number.isFinite(v) ? v : null } };
    case 'contact': return { booleanState: { stateValue: v ?? false } };
    case 'occupancy': return { occupancySensing: { occupancy: { occupied: v ?? false } } };
    case 'airPurifier':
    case 'fan': return { fanControl: { fanMode: d.on ? 3 : 0, fanModeSequence: 0,
      percentSetting: d.on ? Math.round(a.percent ?? 0) : 0, percentCurrent: d.on ? Math.round(a.percent ?? 0) : 0 } };
    default: return {
      onOff: { onOff: d.on ?? false },
      ...(['dimmableLight', 'colorTemperatureLight'].includes(d.kind) ? { levelControl: { currentLevel: Math.max(1, Math.round((a.level ?? 1) * 254 / 100)) } } : {}),
      ...(d.kind === 'colorTemperatureLight' ? { colorControl: { coupleColorTempToLevelMinMireds: a.colorTemperatureMin ?? 1, remainingTime: 0, colorMode: 2, enhancedColorMode: 2, colorTemperatureMireds: a.colorTemperature ?? 250, colorTempPhysicalMinMireds: a.colorTemperatureMin ?? 1, colorTempPhysicalMaxMireds: a.colorTemperatureMax ?? 65279 } } : {}),
    };
  }
}

export function controls(device, write, syncing) {
  const result = [];
  if (['dimmableLight', 'colorTemperatureLight'].includes(device.kind)) {
    class DeviceLevel extends LevelControlServer.with('OnOff', 'Lighting') {
      moveToLevelLogic(level, _time, withOnOff) { return this.apply(level, withOnOff); }
      async moveToLevel({ level }) { await this.apply(level, false); }
      async moveToLevelWithOnOff({ level }) { await this.apply(level, true); }
      async step({ stepMode, stepSize }) { await this.apply(this.state.currentLevel + (stepMode ? -stepSize : stepSize), false); }
      async stepWithOnOff({ stepMode, stepSize }) { await this.apply(this.state.currentLevel + (stepMode ? -stepSize : stepSize), true); }
      move() { throw new Error('Continuous dimming unavailable'); }
      moveWithOnOff() { throw new Error('Continuous dimming unavailable'); }
      stop() {}
      stopWithOnOff() {}
      async apply(level, power) {
        level = Math.max(0, Math.min(254, level));
        if (power) await this.agent.get(OnOffServer)[level > 0 ? 'on' : 'off']();
        if (level > 0) {
          const confirmed = await write('level', level * 100 / 254);
          this.state.currentLevel = Math.max(1, Math.round(confirmed.attributes.level * 254 / 100));
        }
      }
    }
    result.push(DeviceLevel);
  }
  if (device.kind === 'colorTemperatureLight') {
    class DeviceColor extends ColorControlServer.with('ColorTemperature') {
      moveToColorTemperatureLogic(value) { return this.moveToColorTemperature({ colorTemperatureMireds: value }); }
      async moveToColorTemperature({ colorTemperatureMireds }) {
        const d = await write('colorTemperature', colorTemperatureMireds);
        this.state.colorTemperatureMireds = d.attributes.colorTemperature;
      }
      async stepColorTemperature({ stepMode, stepSize }) {
        await this.moveToColorTemperature({ colorTemperatureMireds: this.state.colorTemperatureMireds + (stepMode === 3 ? -stepSize : stepSize) });
      }
      moveColorTemperature() { throw new Error('Continuous color transition unavailable'); }
    }
    result.push(DeviceColor);
  }
  if (['fan', 'airPurifier'].includes(device.kind)) {
    class DeviceFan extends FanControlServer {
      initialize() {
        super.initialize();
        this.reactTo(this.events.percentSetting$Changing, this.percentChanging);
        this.reactTo(this.events.fanMode$Changing, this.modeChanging);
      }
      percentChanging(value) {
        if (syncing.has(device.did)) return;
        if (value == null) throw new Error('Automatic fan mode unavailable');
        this.state.percentCurrent = value;
        this.confirmBeforeCommit('percent', async () => {
          if (value > 0) await write('percent', value);
          await write('on', value > 0);
        });
      }
      modeChanging(value) {
        if (syncing.has(device.did)) return;
        if (![0, 1, 2, 3, 5].includes(value)) throw new Error('Fan mode unavailable');
        const percent = value === 0 ? 0 : value === 1 ? 33 : value === 2 ? 66 : 100;
        this.state.percentCurrent = percent;
        this.confirmBeforeCommit('mode', async () => {
          if (value > 0) await write('percent', percent);
          await write('on', value > 0);
        });
      }
      confirmBeforeCommit(key, action) {
        let done = false;
        this.context.transaction.addParticipants({
          toString: () => device.did + ':fan:' + key,
          async preCommit() { if (!done) { done = true; await action(); } return false; },
        });
      }
    }
    result.push(DeviceFan);
  }
  if (device.kind === 'occupancy') result.push(OccupancySensingServer.with('PassiveInfrared'));
  return result;
}
