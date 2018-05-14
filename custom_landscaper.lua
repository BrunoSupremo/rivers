local Array2D = require 'stonehearth.services.server.world_generation.array_2D'
local SimplexNoise = require 'stonehearth.lib.math.simplex_noise'
local FilterFns = require 'stonehearth.services.server.world_generation.filter.filter_fns'
local water_shallow = 'water_1'
local water_deep = 'water_2'
local CustomLandscaper = class()

local Astar = require 'astar'
local noise_height_map --this noise is to mess with the astar to avoid straight line rivers
local regions --.size, .start and .ending
local min_required_region_size = 10
local rivers_info
local log = radiant.log.create_logger('meu_log')

function CustomLandscaper:mark_water_bodies_original(elevation_map, feature_map)
   local rng = self._rng
   local biome = self._biome
   local config = self._landscape_info.water.noise_map_settings
   local modifier_map, density_map = self:_get_filter_buffers(feature_map.width, feature_map.height)
   --fill modifier map to push water bodies away from terrain type boundaries
   local modifier_fn = function (i,j)
      if self:_is_flat(elevation_map, i, j, 1) then
         return 0
      else
         return -1*config.range
      end
   end
   --use density map as buffer for smoothing filter
   density_map:fill(modifier_fn)
   FilterFns.filter_2D_0125(modifier_map, density_map, modifier_map.width, modifier_map.height, 10)
   --mark water bodies on feature map using density map and simplex noise
   local old_feature_map = Array2D(feature_map.width, feature_map.height)
   for j=1, feature_map.height do
      for i=1, feature_map.width do
         local occupied = feature_map:get(i, j) ~= nil
         if not occupied then
            local elevation = elevation_map:get(i, j)
            local terrain_type = biome:get_terrain_type(elevation)
            local value = SimplexNoise.proportional_simplex_noise(config.octaves,config.persistence_ratio, config.bandlimit,config.mean[terrain_type],config.range,config.aspect_ratio, self._seed,i,j)
            value = value + modifier_map:get(i,j)
            if value > 0 then
               local old_value = feature_map:get(i, j)
               old_feature_map:set(i, j, old_value)
               feature_map:set(i, j, water_shallow)
            end
         end
      end
   end
   self:_remove_juts(feature_map)
   self:_remove_ponds(feature_map, old_feature_map)
   self:_fix_tile_aligned_water_boundaries(feature_map, old_feature_map)
   self:_add_deep_water(feature_map)
end

function CustomLandscaper:generate_defaults()
	rivers_info = {}
	rivers_info.keep_default_lake_generation = true
	rivers_info.wide = {}
	rivers_info.wide.min = 0
	rivers_info.wide.max = 0
	rivers_info.wide.allowed_at = {}
	rivers_info.wide.allowed_at.plains = true
	rivers_info.wide.allowed_at.foothills = false
	rivers_info.wide.allowed_at.mountains = false
	rivers_info.narrow = {}
	rivers_info.narrow.min = 1
	rivers_info.narrow.max = 1
	rivers_info.narrow.allowed_at = {}
	rivers_info.narrow.allowed_at.plains = true
	rivers_info.narrow.allowed_at.foothills = false
	rivers_info.narrow.allowed_at.mountains = false
end

function CustomLandscaper:mark_water_bodies(elevation_map, feature_map)
	local rng = self._rng
	local biome = self._biome

	rivers_info = self._landscape_info.water.rivers
	if not rivers_info then
		self:generate_defaults()
	end

	if rivers_info.keep_default_lake_generation then
		--this is the same as the original mark_water_... function as found in the stonehearth mod
		self:mark_water_bodies_original(elevation_map,feature_map)
	end
	rivers_info.wide.fixed = rng:get_int(rivers_info.wide.min, rivers_info.wide.max)
	rivers_info.narrow.fixed = rng:get_int(rivers_info.narrow.min, rivers_info.narrow.max)
	if rivers_info.wide.fixed + rivers_info.narrow.fixed <1 then
		return
	end

	noise_height_map = {}
	noise_height_map.width = feature_map.width
	noise_height_map.height = feature_map.height
	for j=1, feature_map.height do
		for i=1, feature_map.width do
			local elevation = elevation_map:get(i, j)
			local terrain_type = biome:get_terrain_type(elevation)

			local offset = (j-1)*feature_map.width+i
			--creates and set the points
			noise_height_map[offset] = {}
			noise_height_map[offset].x = i
			noise_height_map[offset].y = j
			noise_height_map[offset].elevation = elevation
			noise_height_map[offset].terrain_type = terrain_type
			noise_height_map[offset].noise = rng:get_int(1,100)
		end
	end
	self:mark_borders() --it is important to avoid generating close to the borders
	if self:river_create_regions() then -- try to create and check if regions exist to spawn rivers
		self:add_rivers(feature_map)
	end
end

function CustomLandscaper:mark_borders()
	local radius = 2
	if rivers_info.wide.fixed <1 then
		radius = 1
	end
	local allowed_at = {
		plains = rivers_info.wide.allowed_at.plains or rivers_info.narrow.allowed_at.plains,
		foothills = rivers_info.wide.allowed_at.foothills or rivers_info.narrow.allowed_at.foothills,
		mountains = rivers_info.wide.allowed_at.mountains or rivers_info.narrow.allowed_at.mountains 
	}
	local function neighbors_have_different_elevations(x,y,offset)
		if not allowed_at[noise_height_map[offset].terrain_type] then
			return true
		end
		for j=y-radius, y+radius do --the border will be 2 tiles thick
			for i=x-radius, x+radius do
				local neighbor_offset = (j-1)*noise_height_map.width+i
				if noise_height_map[neighbor_offset] then
					if noise_height_map[neighbor_offset].elevation ~= noise_height_map[offset].elevation then
						return true
					end
				end
			end
		end
		return false
	end

	if noise_height_map.width>50 then
		--for big (default) worlds, excludes the non-visible portion of the map
		for y=1, noise_height_map.height do
			for x=1, noise_height_map.width do
				local offset = (y-1)*noise_height_map.width+x
				noise_height_map[offset].border = true
			end
		end
		for y=32, noise_height_map.height-31 do
			for x=32, noise_height_map.width-31 do
				local offset = (y-1)*noise_height_map.width+x
				noise_height_map[offset].border = neighbors_have_different_elevations(x,y,offset)
			end
		end
	else
		--tiny world, use it all
		for y=1, noise_height_map.height do
			for x=1, noise_height_map.width do
				local offset = (y-1)*noise_height_map.width+x
				noise_height_map[offset].border = neighbors_have_different_elevations(x,y,offset)
			end
		end
	end
end

function CustomLandscaper:river_create_regions()
	regions = {}
	--creates multiple regions, where each point has a path to any other within the region
	local has_at_least_one_usable_area = false
	local region_index = 1
	for y=1, noise_height_map.height do
		for x=1, noise_height_map.width do
			local offset = (y-1)*noise_height_map.width+x
			if not noise_height_map[offset].border then
				if not noise_height_map[offset].region then
					local region_candidate = self:river_flood_fill_region(x,y, region_index)

					if region_candidate.size>min_required_region_size then
						has_at_least_one_usable_area = true
						regions[region_index] = region_candidate
						region_index = region_index +1
					end
				end
			end
		end
	end

	--this is used to procced or skip the river generation (no need to try if there is no space)
	return has_at_least_one_usable_area
end

function CustomLandscaper:river_flood_fill_region(x,y, region)
	local offset = (y-1)*noise_height_map.width+x
	local openset = {}

	local start = offset
	local ending = offset

	local current
	local index = 1
	local size = 1
	openset[index] = offset
	noise_height_map[offset].checked = true
	while openset[index]~=nil do
		--find the most distant point in this region from that initially chosen
		current = noise_height_map[ openset[index] ]
		noise_height_map[ openset[index] ].region = region

		local offset_left = (current.y-1)*noise_height_map.width+current.x -1
		if current.x>1 and noise_height_map[offset_left].border==false and not noise_height_map[offset_left].checked then
			size = size +1
			openset[size] = offset_left
			noise_height_map[offset_left].checked = true
		end

		local offset_right = (current.y-1)*noise_height_map.width+current.x +1
		if current.x<noise_height_map.width and noise_height_map[offset_right].border==false and not noise_height_map[offset_right].checked then
			size = size +1
			openset[size] = offset_right
			noise_height_map[offset_right].checked = true
		end

		local offset_up = (current.y-2)*noise_height_map.width+current.x
		if current.y>1 and noise_height_map[offset_up].border==false and not noise_height_map[offset_up].checked then
			size = size +1
			openset[size] = offset_up
			noise_height_map[offset_up].checked = true
		end

		local offset_down = (current.y)*noise_height_map.width+current.x
		if current.y<noise_height_map.height and noise_height_map[offset_down].border==false and not noise_height_map[offset_down].checked then
			size = size +1
			openset[size] = offset_down
			noise_height_map[offset_down].checked = true
		end

		index = index +1
	end
	start = openset[size]

	if size > min_required_region_size then
		--reverse the flood to find the oposing most distant point
		local second_openset = {}
		index = 1
		size = 1
		second_openset[index] = start
		noise_height_map[start].second_pass = true
		while second_openset[index]~=nil do
			current = noise_height_map[ second_openset[index] ]

			local offset_left = (current.y-1)*noise_height_map.width+current.x -1
			if current.x>1 and noise_height_map[offset_left].border==false and not noise_height_map[offset_left].second_pass then
				size = size +1
				second_openset[size] = offset_left
				noise_height_map[offset_left].second_pass = true
			end

			local offset_right = (current.y-1)*noise_height_map.width+current.x +1
			if current.x<noise_height_map.width and noise_height_map[offset_right].border==false and not noise_height_map[offset_right].second_pass then
				size = size +1
				second_openset[size] = offset_right
				noise_height_map[offset_right].second_pass = true
			end

			local offset_up = (current.y-2)*noise_height_map.width+current.x
			if current.y>1 and noise_height_map[offset_up].border==false and not noise_height_map[offset_up].second_pass then
				size = size +1
				second_openset[size] = offset_up
				noise_height_map[offset_up].second_pass = true
			end

			local offset_down = (current.y)*noise_height_map.width+current.x
			if current.y<noise_height_map.height and noise_height_map[offset_down].border==false and not noise_height_map[offset_down].second_pass then
				size = size +1
				second_openset[size] = offset_down
				noise_height_map[offset_down].second_pass = true
			end

			index = index +1
		end
		ending = second_openset[size]
	end

	return {size = size, start = start, ending = ending}
end

function CustomLandscaper:add_rivers(feature_map)

	local function grab_bigest_region()
		local bigest_region = 0
		local current_bigest_size = 0

		for i,v in pairs(regions) do
			if regions[i].size > current_bigest_size then
				bigest_region = i
				current_bigest_size = regions[i].size
			end
		end
		if bigest_region <1 then
			return nil
		end
		return bigest_region
	end

	while rivers_info.wide.fixed + rivers_info.narrow.fixed >0 do
		local region = grab_bigest_region()
		if not region then break end

		local start = regions[region].start
		local ending = regions[region].ending

		if rivers_info.wide.fixed >0 and rivers_info.wide.allowed_at[ noise_height_map[start].terrain_type ] then
			self:draw_river(noise_height_map[start], noise_height_map[ending], feature_map, "wide")
			rivers_info.wide.fixed = rivers_info.wide.fixed -1
		else
			if rivers_info.narrow.fixed >0 and rivers_info.narrow.allowed_at[ noise_height_map[start].terrain_type ] then
				self:draw_river(noise_height_map[start], noise_height_map[ending], feature_map, "narrow")
				rivers_info.narrow.fixed = rivers_info.narrow.fixed -1
			end
		end
		regions[region] = nil
	end
end

function CustomLandscaper:draw_river(start,goal,feature_map, size)
	local path = Astar.path ( start, goal, noise_height_map, true )

	if not path then
		log:error('Error. No valid river path found!')
	else
		for i, node in ipairs ( path ) do
			if size == "wide" then --wide and deep rivers
				feature_map:set(node.x, node.y, water_deep)
				self:add_shallow_neighbors(node.x, node.y, feature_map)
			else --narrow and shallow rivers
				if feature_map:get(node.x, node.y) ~= water_deep then --avoid overwriting deep with shallow
					feature_map:set(node.x, node.y, water_shallow)
				end
			end
		end
	end
end

function CustomLandscaper:add_shallow_neighbors(x,y, feature_map)
	for j=y-1, y+1 do
		for i=x-1, x+1 do
			local feature_name = feature_map:get(i, j)
			--only where there is no water (else the deep parts would be overwriten)
			if feature_map:in_bounds(i,j) and (not self:is_water_feature(feature_name)) then
				feature_map:set(i, j, water_shallow)
			end
		end
	end
end

return CustomLandscaper