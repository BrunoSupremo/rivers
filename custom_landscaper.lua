local Array2D = require 'stonehearth.services.server.world_generation.array_2D'
local SimplexNoise = require 'stonehearth.lib.math.simplex_noise'
local FilterFns = require 'stonehearth.services.server.world_generation.filter.filter_fns'
local water_shallow = 'water_1'
local water_deep = 'water_2'
local CustomLandscaper = class()

local Astar = require 'astar'
local noise_height_map --this noise is to mess with the astar to avoid straight line rivers
local region_sizes --small areas are ignored, else it will create small pity rivers
local log = radiant.log.create_logger('meu_log')
local biome_name

function CustomLandscaper:mark_water_bodies_check(elevation_map, feature_map)
	local mod_name = stonehearth.world_generation:get_biome_alias()
	-- mod_name is the mod that has the current biome
	local colon_pos = string.find (mod_name, ":", 1, true) or -1
	mod_name = string.sub (mod_name, 1, colon_pos-1)
	local modded_function_name = "mark_water_bodies_" .. mod_name
	if self[modded_function_name]~=nil then
		-- the current biome also mods this same function, so call its proper modded function
		-- e.g. the archipelago has a function named mark_water_bodies_archipelago_biome()
		self[modded_function_name](self, elevation_map, feature_map)
	else
		-- the biome does not have a modded function, so call default river function
		self:mark_water_bodies_rivers(elevation_map, feature_map)
	end
end

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

function CustomLandscaper:mark_water_bodies_rivers(elevation_map, feature_map)
	biome_name = string.match(stonehearth.world_generation:get_biome_alias(), ".*:(%a+)") or "no_alias_biome"
	local keep_original_map_lakes = radiant.util.get_config(biome_name..".keep_original_map_lakes", true)
	if keep_original_map_lakes then
		--this is the same as the original mark_water_... function as found in the stonehearth mod
		self:mark_water_bodies_original(elevation_map,feature_map)
	end

	local rng = self._rng
	local biome = self._biome

	noise_height_map = {}
	noise_height_map.width = feature_map.width
	noise_height_map.height = feature_map.height
	for j=1, feature_map.height do
		for i=1, feature_map.width do
			local elevation = elevation_map:get(i, j)

			local offset = (j-1)*feature_map.width+i
			--creates and set the points
			noise_height_map[offset] = {}
			noise_height_map[offset].x = i
			noise_height_map[offset].y = j
			noise_height_map[offset].elevation = elevation
			noise_height_map[offset].noise = rng:get_int(1,100)
		end
	end
	self:mark_borders() --it is important to avoid generating close to the borders
	if self:river_create_regions() then -- creates and check for big regions to spawn rivers
		self:add_rivers(feature_map)
	end
end

function CustomLandscaper:mark_borders()
	local function neighbors_have_different_elevations(x,y,offset)
		for j=y-2, y+2 do --the border will be 2 tiles thick
			for i=x-2, x+2 do
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

	for y=1, noise_height_map.height do
		for x=1, noise_height_map.width do
			local offset = (y-1)*noise_height_map.width+x
			noise_height_map[offset].border = neighbors_have_different_elevations(x,y,offset)
		end
	end
end

function CustomLandscaper:river_create_regions()
	region_sizes = {}
	--creates multiple regions, where each point has a path to any other within the region
	local has_at_least_one_big_region = false
	local region = 0
	for y=1, noise_height_map.height do
		for x=1, noise_height_map.width do
			local offset = (y-1)*noise_height_map.width+x
			if not noise_height_map[offset].border then
				if not noise_height_map[offset].region then
					region = region +1
					region_sizes[region] = self:river_flood_fill_region(x,y, region)

					if region_sizes[region]>1500 then -- roughly 38x38 area (19x19 in mini map)
						--the 1500 value was chosen arbitrary, on what I experienced as "good enough"
						has_at_least_one_big_region = true
					end
				end
			end
		end
	end

	--this is used to procced or skip the river generation (no need to try if there is no space)
	return has_at_least_one_big_region
end

function CustomLandscaper:river_flood_fill_region(x,y, region)
	local offset = (y-1)*noise_height_map.width+x
	local size = 0
	local openset = {}

	table.insert( openset, noise_height_map[offset] )

	while #openset>0 do
		local current = table.remove(openset)
		current.region = region
		size = size +1

		local offset_left = (current.y-1)*noise_height_map.width+current.x -1
		if current.x>1 and noise_height_map[offset_left].border==false and not noise_height_map[offset_left].region then
			table.insert( openset, noise_height_map[offset_left] )
		end

		local offset_right = (current.y-1)*noise_height_map.width+current.x +1
		if current.x<noise_height_map.width and noise_height_map[offset_right].border==false and not noise_height_map[offset_right].region then
			table.insert( openset, noise_height_map[offset_right] )
		end

		local offset_up = (current.y-2)*noise_height_map.width+current.x
		if current.y>1 and noise_height_map[offset_up].border==false and not noise_height_map[offset_up].region then
			table.insert( openset, noise_height_map[offset_up] )
		end

		local offset_down = (current.y)*noise_height_map.width+current.x
		if current.y<noise_height_map.height and noise_height_map[offset_down].border==false and not noise_height_map[offset_down].region then
			table.insert( openset, noise_height_map[offset_down] )
		end
	end

	return size
end

function CustomLandscaper:add_rivers(feature_map)

	local function grab_random_region()
		local region_number
		repeat
			region_number = self._rng:get_int(1, #region_sizes)
		until
			--should only get big regions
			region_sizes[region_number]>1500 -- roughly 38x38 area (19x19 in mini map)
		return region_number
	end

	local function grab_random_point(region)
		local x,y,point_offset
		repeat
			x = self._rng:get_int(1, noise_height_map.width)
			y = self._rng:get_int(1, noise_height_map.height)
			point_offset = (y-1)*noise_height_map.width+x
		until
			noise_height_map[point_offset].border==false and
			--same region means there is path between the points
			noise_height_map[point_offset].region == region
		return point_offset
	end
	
	local function grab_distance_between_points(offset, offset2)
		local dx = noise_height_map[offset2].x-noise_height_map[offset].x
		local dy = noise_height_map[offset2].y-noise_height_map[offset].y
		return math.sqrt(dx*dx + dy*dy)
	end
	
	local function grab_the_two_most_distance_points(offset, offset2, offset3)
		local dist_1_2 = grab_distance_between_points(offset, offset2)
		local dist_1_3 = grab_distance_between_points(offset, offset3)
		local dist_2_3 = grab_distance_between_points(offset2,offset3)

		if dist_1_2 > dist_1_3 and dist_1_2 > dist_2_3 then
			return offset, offset2
		else
			if dist_1_3 > dist_1_2 and dist_1_3 > dist_2_3 then
				return offset, offset3
			else
				return offset2, offset3
			end
		end
	end

	local narrow_river_counter = radiant.util.get_config(biome_name..".narrow_river_counter", 1)
	local wide_river_counter = radiant.util.get_config(biome_name..".wide_river_counter", 1)
	local offset,offset2,offset3, region

	for rivers=1, narrow_river_counter do
		region = grab_random_region()

		offset = grab_random_point(region)
		offset2 = grab_random_point(region)
		offset3 = grab_random_point(region)
		
		--sometimes the chosen two points are too close, making lame rivers.
		--thats why I'm using 3 points and from that grabbing the two most far from each other.
		--this decreases the chances of having super close start and end points
		offset,offset2 = grab_the_two_most_distance_points(offset, offset2, offset3)

		self:draw_river(noise_height_map[offset], noise_height_map[offset2], feature_map,"narrow")
	end
	for rivers=1, wide_river_counter do
		region = grab_random_region()

		offset = grab_random_point(region)
		offset2 = grab_random_point(region)
		offset3 = grab_random_point(region)

		offset,offset2 = grab_the_two_most_distance_points(offset, offset2, offset3)

		self:draw_river(noise_height_map[offset], noise_height_map[offset2], feature_map,"wide")
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