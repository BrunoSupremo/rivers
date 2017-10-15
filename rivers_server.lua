rivers = {}

function rivers:_on_required_loaded()
	local custom_landscaper = require('custom_landscaper')
	local landscaper = radiant.mods.require('stonehearth.services.server.world_generation.landscaper')
	radiant.mixin(landscaper, custom_landscaper)

	local custom_world_generation_service = require('custom_world_generation_service')
	local world_generation_service = radiant.mods.require('stonehearth.services.server.world_generation.world_generation_service')
	radiant.mixin(world_generation_service, custom_world_generation_service)

	local config = radiant.util.get_config('temperate')
	if not config then
		radiant.util.set_config("temperate.narrow_river_counter", 5)
		radiant.util.set_config("temperate.wide_river_counter", 3)
		radiant.util.set_config("temperate.keep_original_map_lakes", false)
		radiant.util.set_config("desert.narrow_river_counter", 3)
		radiant.util.set_config("desert.wide_river_counter", 0)
		radiant.util.set_config("desert.keep_original_map_lakes", false)
		radiant.util.set_config("swamp.narrow_river_counter", 0)
		radiant.util.set_config("swamp.wide_river_counter", 5)
		radiant.util.set_config("swamp.keep_original_map_lakes", true)
	end
end

radiant.events.listen_once(radiant, 'radiant:required_loaded', rivers, rivers._on_required_loaded)

return rivers