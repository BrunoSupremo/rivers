rivers = {}

function rivers:_on_required_loaded()
	local custom_landscaper = require('custom_landscaper')
	local landscaper = radiant.mods.require('stonehearth.services.server.world_generation.landscaper')
	radiant.mixin(landscaper, custom_landscaper)
end

radiant.events.listen_once(radiant, 'radiant:required_loaded', rivers, rivers._on_required_loaded)

return rivers