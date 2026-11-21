import { Millis, Time } from '@matter/main';
import { miredsToXy } from '@matter/main/behaviors/color-control';
import { ExtendedColorLightRequirements } from '@matter/main/devices/extended-color-light';
import { ColorControl } from '@matter/main/clusters/color-control';
import { Status, StatusResponseError } from '@matter/types';

const scale = 65536;
const maxXY = 0xfeff;
const xyMode = ColorControl.ColorMode.CurrentXAndCurrentY;
const ctMode = ColorControl.ColorMode.ColorTemperatureMireds;
export const minMireds = 154; // approximately 6500 K
export const maxMireds = 370; // approximately 2700 K

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
export const isAmbientRgb = value => Number.isInteger(value) && value >= 1 && value <= 0xffffff;

export function rgbToMatterXY(rgb) {
  if (!isAmbientRgb(rgb)) throw new RangeError('Invalid ambient RGB');
  const [r, g, b] = [rgb >> 16, (rgb >> 8) & 255, rgb & 255].map(byte => {
    const component = byte / 255;
    return component <= 0.04045 ? component / 12.92 : ((component + 0.055) / 1.055) ** 2.4;
  });
  const X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
  const Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
  const Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;
  return [X, Y].map(value => Math.round(scale * value / (X + Y + Z)));
}

function xyToRgb(x, y) {
  // sRGB D65 transform. Clip out-of-gamut components and normalize chromaticity.
  // Level Control carries the physical light's independent brightness.
  const z = 1 - x - y;
  const linear = [
    3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
    -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
    0.0556434 * x - 0.2040259 * y + 1.0572252 * z,
  ].map(value => Math.max(0, value));
  const peak = Math.max(...linear);
  return linear.reduce((rgb, component) => {
    const value = component / peak;
    const encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - 0.055;
    return (rgb << 8) | Math.round(255 * encoded);
  }, 0);
}

export function matterXYToRgb(x, y) {
  if (![x, y].every(v => Number.isInteger(v) && v >= 0 && v <= maxXY) || x + y > scale) {
    throw new StatusResponseError('Invalid CIE chromaticity', Status.ConstraintError);
  }
  return xyToRgb(x / scale, y / scale);
}

// Use the pinned library's Planckian chromaticity table. Compare against the
// *rendered* RGB points so a white-point write and a later bg_rgb read agree.
const whitePoints = Array.from({ length: maxMireds - minMireds + 1 }, (_, index) => {
  const rgb = xyToRgb(...miredsToXy(index + minMireds));
  return { rgb, xy: rgbToMatterXY(rgb) };
});

export const miredsToRgb = mireds => whitePoints[clamp(Math.round(mireds), minMireds, maxMireds) - minMireds].rgb;

export function ambientColorState(rgb, previous) {
  const [currentX, currentY] = rgbToMatterXY(rgb);
  let nearest = 0;
  let distance = Infinity;
  for (const [index, { xy }] of whitePoints.entries()) {
    const error = (currentX - xy[0]) ** 2 + (currentY - xy[1]) ** 2;
    if (error < distance) { distance = error; nearest = index; }
  }
  const mode = previous?.currentX === currentX && previous.currentY === currentY ? previous.colorMode : xyMode;
  return { currentX, currentY, colorMode: mode, enhancedColorMode: mode, colorTemperatureMireds: minMireds + nearest };
}

export function ambientColorBehavior(write) {
  // The generated behavior provides required XY, CT, RemainingTime and option checks.
  const Base = ExtendedColorLightRequirements.ColorControlServer;
  let movement;

  function cancel() {
    movement?.timer?.stop();
    movement = undefined;
  }

  return class AmbientColor extends Base {
    initialize() {
      this.endpoint.lifecycle.destroyed.on(cancel);
      return super.initialize();
    }

    // Both representations already derive from RGB readback.
    switchColorMode() { this.stopAmbientMovement(); }
    stopAllColorMovement() { this.stopAmbientMovement(); }
    stopHueAndSaturationMovement() { this.stopAmbientMovement(); }
    stopMoveStepLogic() { this.stopAmbientMovement(); }

    stopAmbientMovement() {
      cancel();
      this.state.remainingTime = 0;
    }

    async apply(mode, target) {
      const rgb = mode === ctMode ? miredsToRgb(target[0]) : matterXYToRgb(...target);
      const confirmed = await write('rgb', rgb);
      Object.assign(this.state, ambientColorState(confirmed.attributes.rgb), {
        colorMode: mode, enhancedColorMode: mode,
      });
    }

    transition(mode, from, to, tenths) {
      this.stopAmbientMovement();
      const duration = Math.round(clamp(tenths, 0, 65534)) * 100;
      if (duration === 0) return this.apply(mode, to);

      const endpoint = this.endpoint;
      const Behavior = this.constructor;
      const job = { started: Time.nowMs, timer: undefined };
      movement = job;
      this.state.remainingTime = duration / 100;

      // Pace LAN writes and confirm each sample before scheduling the next one.
      const next = remaining => {
        job.timer = Time.getTimer('ambient-color-transition', Millis(Math.min(remaining, 1000)), async () => {
          if (movement !== job) return;
          try {
            await endpoint.act(async agent => {
              if (movement !== job) return;
              const behavior = agent.get(Behavior);
              const fraction = Math.min(1, (Time.nowMs - job.started) / duration);
              const target = from.map((value, i) => Math.round(value + (to[i] - value) * fraction));
              if (mode === xyMode) target[1] = Math.min(target[1], scale - target[0]);
              await behavior.apply(mode, target);
              const remaining = Math.max(0, duration - (Time.nowMs - job.started));
              behavior.state.remainingTime = fraction === 1 ? 0 : Math.ceil(remaining / 100);
              if (fraction < 1) next(Math.max(1, remaining));
              else movement = undefined;
            });
          } catch {
            if (movement !== job) return;
            cancel();
            if (!endpoint.lifecycle.isDestroyed) {
              await endpoint.act(agent => { agent.get(Behavior).state.remainingTime = 0; });
            }
          }
        }).start();
      };
      next(duration);
    }

    moveToColorLogic(x, y, time) {
      matterXYToRgb(x, y); // Validate the target before accepting a timed command.
      return this.transition(xyMode, [this.state.currentX, this.state.currentY], [x, y], time);
    }

    stepColorLogic(x, y, time) {
      const targetX = clamp(this.state.currentX + x, 0, maxXY);
      const targetY = clamp(this.state.currentY + y, 0, Math.min(maxXY, scale - targetX));
      return this.moveToColorLogic(targetX, targetY, time);
    }

    moveColorLogic(rateX, rateY) {
      const { currentX: x, currentY: y } = this.state;
      const times = [rateX, rateY].map((rate, index) => {
        if (!rate) return Infinity;
        return ((rate > 0 ? maxXY : 0) - [x, y][index]) / rate;
      });
      if (rateX + rateY > 0) times.push((scale - x - y) / (rateX + rateY));
      const seconds = clamp(Math.min(...times), 0, 6553.4);
      const targetX = clamp(Math.round(x + seconds * rateX), 0, maxXY);
      const targetY = clamp(Math.round(y + seconds * rateY), 0, Math.min(maxXY, scale - targetX));
      return this.moveToColorLogic(targetX, targetY, seconds * 10);
    }

    moveToColorTemperatureLogic(mireds, time) {
      return this.transition(ctMode, [this.state.colorTemperatureMireds], [clamp(mireds, minMireds, maxMireds)], time);
    }

    stepColorTemperatureLogic(mode, step, time, min, max) {
      if (min > max) throw new StatusResponseError('Invalid CT bounds', Status.ConstraintError);
      const direction = mode === ColorControl.StepMode.Up ? 1 : -1;
      return this.moveToColorTemperatureLogic(clamp(this.state.colorTemperatureMireds + direction * step, min, max), time);
    }

    moveColorTemperatureLogic(mode, rate, min, max) {
      if (min > max) throw new StatusResponseError('Invalid CT bounds', Status.ConstraintError);
      const target = mode === ColorControl.MoveMode.Up ? max : min;
      return this.moveToColorTemperatureLogic(target, Math.abs(target - this.state.colorTemperatureMireds) * 10 / rate);
    }
  };
}
