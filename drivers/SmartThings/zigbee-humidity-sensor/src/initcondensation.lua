-- Copyright 2022 SmartThings
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

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local TemperatureMeasurement = (require "st.zigbee.zcl.clusters").TemperatureMeasurement
local configurationMap = require "configurations"

-- Constants for dew point calculation
local A = 17.27
local B = 237.7

-- Function to calculate dew point
local function calculate_dew_point(temp, humidity)
  local alpha = ((A * temp) / (B + temp)) + math.log(humidity / 100)
  local dew_point = (B * alpha) / (A - alpha)
  return dew_point
end

-- Function to handle temperature and humidity updates
local function check_dew_point(driver, device)
  local temperature = device:get_latest_state("main", capabilities.temperatureMeasurement.ID, capabilities.temperatureMeasurement.temperature.NAME)
  local humidity = device:get_latest_state("main", capabilities.relativeHumidityMeasurement.ID, capabilities.relativeHumidityMeasurement.humidity.NAME)

  if temperature and humidity then
    local dew_point = calculate_dew_point(temperature, humidity)
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = dew_point, unit = "C" })) -- Emit dew point for reference
    
    if temperature <= dew_point then
      device:emit_event(capabilities.contactSensor.contact.closed()) -- Trigger an automation event
      device.log.info("Temperature has intercepted or fallen below the dew point.")
    end
  end
end

local function temperature_humidity_handler(driver, device, zb_rx)
  check_dew_point(driver, device)
end

local function device_init(driver, device)
  local configuration = configurationMap.get_device_configuration(device)
  if configuration ~= nil then
    for _, attribute in ipairs(configuration) do
      device:add_configured_attribute(attribute)
      device:add_monitored_attribute(attribute)
    end
  end
end

local function added_handler(driver, device)
  device:send(TemperatureMeasurement.attributes.MaxMeasuredValue:read(device))
  device:send(TemperatureMeasurement.attributes.MinMeasuredValue:read(device))
end

local zigbee_humidity_driver = {
  supported_capabilities = {
    capabilities.battery,
    capabilities.relativeHumidityMeasurement,
    capabilities.temperatureMeasurement,
    capabilities.contactSensor, -- Added for automation event
  },
  zigbee_handlers = {
    attr = {
      [TemperatureMeasurement.ID] = {
        [TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_humidity_handler,
      }
    }
  },
  lifecycle_handlers = {
    init = device_init,
    added = added_handler,
  },
  sub_drivers = {
    require("aqara"),
    require("plant-link"),
    require("plaid-systems"),
    require("centralite-sensor"),
    require("heiman-sensor"),
    require("frient-sensor")
  }
}

defaults.register_for_default_handlers(zigbee_humidity_driver, zigbee_humidity_driver.supported_capabilities)
local driver = ZigbeeDriver("zigbee-humidity-sensor", zigbee_humidity_driver)
driver:run()
