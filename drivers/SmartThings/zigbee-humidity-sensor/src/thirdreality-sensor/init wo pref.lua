-- Copyright 2025 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- Thirdreality Humidity Senso
-- Author: Keith Collins
-- Original date: March 1, 2025
-- The primary motivation for this subdriver is to implement condensation event automation. The driver adds
-- virtual dewPoint to track when Temperature intersects Dewpoint and turning on a virtual switch to
-- enable automation. Dewpoint is constantly updated as Temperature and Dewpoint rises.
-- 
-- The challenge is how frequently to update Dewpoint when temperature is falling. If you recalculate
-- to frequently then Temperature will never intersect Dewpoint. Hence the RHoffset preference to 
-- set how much Relative Humidity must fall before recalculating Dewpoint again.
--
-- The goal was to use a single sensor attached to hvac ducts in humid coastal conditions to warn if
-- there is likely condensation occurring on the duct work. 
-- 
-- If others are interested please feel free to improve on the methodology. If there is sufficient
-- interest it would be nice to move this into the default handler.
-- 
-- Smartthings UI applies the offset for humidity and temperature. To make sure Dewpoint is correct
-- wrt offsets they are used in calculating Dewpoint.
-- 
-- This subdriver adds support for Thirdreality 3RTHS0224Z. The device reports that it supports battery
-- Need the manufacture to specify if this is indeed supported and if so what are the proper defaults for
-- the init handler and default for configuration reporting. 
-- This device also responds with success for temp min/max but always returns -32768
local capabilities = require "st.capabilities"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"
local TemperatureMeasurement = (require "st.zigbee.zcl.clusters").TemperatureMeasurement
local RelativeHumidityMeasurement = (require "st.zigbee.zcl.clusters").RelativeHumidity
local configurationMap = require "configurations"

local FINGERPRINTS = {
  { mfr = "Third Reality", model = "3RTHS0224Z" },
}

local function can_handle_tr_sensor(opts, driver, device)
  for _, fingerprint in ipairs(FINGERPRINTS) do
    if device:get_manufacturer() == fingerprint.mfr and device:get_model() == fingerprint.model then
      return true
    end
  end
  return false
end


local function calculate_dew_point(temp, humidity)
  if humidity <= 0 then return temp end  -- Prevents log(0) errors
  if humidity > 100 then humidity = 100 end  -- Caps RH at 100%

  local A = 17.27
  local B = 237.7
  local alpha = ((A * temp) / (B + temp)) + math.log(math.max(humidity, 1) / 100) -- Ensure humidity is always >0
  local dew_point = (B * alpha) / (A - alpha)
  
  return dew_point
end


--------------------------------------------------------------------------------
local function check_dew_point_and_trigger_event(device, current_temp, current_hum)
  -- Retrieve the last switch state; using "off" as the default (not active)
  local last_switch = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) or "off"
  device.log.debug(string.format("Temp: %s, Humidity: %s, Switch: %s", tostring(current_temp), tostring(current_hum), tostring(last_switch)))
-- if current temp nil then retrieve last temp 
  if current_temp == nil then
      current_temp = device:get_latest_state("main", capabilities.temperatureMeasurement.ID, "temperature")
      -- if temp not set return and wait for temp update 
      if (current_temp == nil) then return end
  end

  -- if current humidity nill then retreive las humidity 
  if current_hum == nil
  then
      current_hum = device:get_latest_state("main", capabilities.relativeHumidityMeasurement.ID, "humidity")
        -- if humidity not set return then wait for humidity update 
      if current_hum == nil then return end
  end
  -- apply preferences offset before calculating dewpoint to match offset handing in the UI
  current_hum = current_hum + (device.preferences.humOffset or 0)
  current_temp = current_temp + (device.preferences.tempOffset or 0)

  local last_hum = device:get_field("LAST_HUMIDITY")
  local last_temp = device:get_field("LAST_TEMP")
  local rhThreshold = device.preferences.rhThreshold or 10.0
--  device.log.debug(string.format("Check threshold: %.2f%%", rhThreshold))

  local dewpoint = device:get_latest_state("main", capabilities.dewPoint.ID,"dewpoint")
--  device.log.debug(string.format("Current Temp: %.2f°C, Humidity: %.2f%%, last_temp: %s, last_hum: %s", current_temp, current_hum, last_temp, last_hum))

  local new_dewpoint = calculate_dew_point(current_temp, current_hum)

-- if any are unitialized set dewpoint
-- if the dewpoint or temperature is rising or rh is falling then reset dewpoint 
if (dewpoint == nil) or (last_temp == nil) or (last_hum == nil) or
    (current_temp > last_temp) or (new_dewpoint > dewpoint) or
    (last_hum - current_hum >rhThreshold)
then
      dewpoint = new_dewpoint    
      device:emit_event(capabilities.dewPoint.dewpoint({ value = dewpoint, unit = "C" }))
      device:set_field("LAST_HUMIDITY", current_hum)
      device:set_field("LAST_TEMP", current_temp)
      device.log.debug(string.format("Dewpoint changed *** Current Temp: %.2f°C, Humidity: %.2f%%, Dewpoint: %.2f°C", current_temp, current_hum, dewpoint))
  end

  -- When the temperature is within 1 degree of the dew point, we consider condensation imminent.
  if current_temp < (dewpoint + 1.0) and (last_switch == "off") then
      device.log.info("Condensation imminent")
      device:emit_event(capabilities.switch.switch.on())
    end

  -- When the temperature rises above 1 degree of the dew point, clear the alert.
  if current_temp > (dewpoint + 1.0) and (last_switch == "on") then
      device.log.info("Condensation over")
      device:emit_event(capabilities.switch.switch.off())
    end
  end

local function temperature_change_handler(driver, device, value, zb_rx)
  local raw_temp = value and value.value or 0
  local celc_temp = raw_temp / 100.0
  local temp_scale = "C"
  device:emit_event(capabilities.temperatureMeasurement.temperature({ value = celc_temp, unit = temp_scale }))
  check_dew_point_and_trigger_event(device, celc_temp, nil)
end

local function humidity_change_handler(driver, device, value, zb_rx)
  local humidity = value.value / 100.0
  device:emit_event(capabilities.relativeHumidityMeasurement.humidity({ value = humidity, unit = "%" }))
  check_dew_point_and_trigger_event(device, nil, humidity)
end

local function device_init(driver, device)
  local configuration = configurationMap.get_device_configuration(device)
  if configuration ~= nil then
    for _, attribute in ipairs(configuration) do
      device:add_configured_attribute(attribute)
      device:add_monitored_attribute(attribute)
    end
  end
    -- need to find out what is correct here. assuming standard 1.5v aaa batteries
  battery_defaults.build_linear_voltage_init(2.6, 3.0)(driver, device)  

    -- Default sensor state
  device:set_field("LAST_HUMIDITY", nil)  
  device:set_field("LAST_TEMP", nil)
  device.log.debug("Init TR done:")
end

local function info_changed(driver, device, event, args)
  -- should? add code to check last state of temp and humidity offsets and force reads to recalculate dewpoint
    local old_threshold = args.old_st_store.preferences.rhThreshold
    local new_threshold = device.preferences.rhThreshold
  
    -- handle first call to info_change at device setup
    if old_threshold == nil or new_threshold == nil
     then return end
    -- Only act if rhThreshold has changed
    if old_threshold ~= new_threshold then
      device.log.debug(string.format(
        "RH Threshold changed from %d to %d, requesting new sensor values",
        old_threshold, new_threshold
      ))
      -- Trigger a read to refresh humidity and temperature and resulting dewpoint.
      device:send(TemperatureMeasurement.attributes.MeasuredValue:read(device))
      device:send(RelativeHumidityMeasurement.attributes.MeasuredValue:read(device))
    end
  device.log.debug("Info_changed TR done:")
end

local function remove_handler(driver, device)
  device.log.debug("Removing device: TR" .. device.device_network_id)
  -- Clear persistent state fields
  device:set_field("LAST_HUMIDITY", nil)
  device:set_field("LAST_TEMP", nil)
  device.log.debug("Cleanup complete for device: " .. device.device_network_id)
end

local tr_sensor = {
  NAME = "Third Reality Humidity Sensor",
  supported_capabilities = {
    capabilities.battery,
    capabilities.relativeHumidityMeasurement,
    capabilities.temperatureMeasurement,
    capabilities.switch,
    capabilities.dewPoint
  },
  zigbee_handlers = {
    attr = {
      [TemperatureMeasurement.ID] = {
        [TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_change_handler
      },
      [RelativeHumidityMeasurement.ID] = {
        [RelativeHumidityMeasurement.attributes.MeasuredValue.ID] = humidity_change_handler
      }
    }
  },
  
  lifecycle_handlers = {
    init = device_init,
    removed = remove_handler,
    infoChanged = info_changed,
  },
  can_handle = can_handle_tr_sensor
}

return tr_sensor
