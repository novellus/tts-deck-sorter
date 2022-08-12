-- code repo: https://github.com/novellus/tts-deck-sorter
-- tabletop simulator workshop: 


function gui_nop()
    -- endpoint function for a button without click functionality
end


function onLoad()
    -- Create UI
    self.createButton({
        click_function = 'gui_nop',
        function_owner = self,
        label          = 'Sorting Bag!',
        font_color     = 'Black',
        height         = 0,  -- text display, not an actual button. There is no pure text tool.
        width          = 0,
        position       = {0, 2, 1.2},
        rotation       = {-45, 0, 0},
        font_size      = 120,
        font_color     = 'White',
    })

    -- set state
    currently_sorting = false
    sorting_locations = {}
    bag_sort_queue = {self}
end


function onObjectEnterContainer(container, object)
    -- check if it entered the sorting bag, if so sort it!
    -- currently_sorting: avoid multiple parallel calls to this function, which overload the physical spawn-space allocations
    if container.guid == self.guid and not currently_sorting then
        currently_sorting = true
        sort_lowest_bag(self, nil)
    end
end

 
function partial(f, arg)
    -- returns a partial function taking the given argument
    return function(...)
        return f(arg, ...)
    end
end


function relative_position(object, row_offset, column_offset, height_offset)
    -- computes a vector providing a world location at specified offset from object
    -- row and column widths are fixed relative to size of master sorting-bag3
    --     Ignoring: objects which are too big may overlap, causing problems
    -- height_offset can be used to prevent physics collisions with very large stacks

    -- compute relative position from object, cols/rows sized relative to master bag size
    self_bounds = self.getBoundsNormalized()  -- position relative to size of master sorting-bag
    self_size = self_bounds.size

    relative_vector = Vector(
        -self_size.x * 2.2 * column_offset,
         self_size.y * 2 * height_offset,
        -self_size.z * 3.2 * row_offset  -- cards are assymetricly sized
    )

    -- rotate relative vector to same angle as the master bag
    self_rotation = self.getRotation()
    relative_vector = relative_vector:rotateOver('x', self_rotation.x)
    relative_vector = relative_vector:rotateOver('y', self_rotation.y)
    relative_vector = relative_vector:rotateOver('z', self_rotation.z)

    -- transform relative vector into world position
    object_position = object.getPosition()

    target_position = object_position + relative_vector
    -- Vector(
    --     object_position.x + relative_vector.x,
    --     object_position.y + relative_vector.y,
    --     object_position.z + relative_vector.z
    -- )

    return target_position
end


function sort_lowest_bag()
    -- Recursively pulls one object at a time from the lowest spawned bag/deck
    -- Each object is removed from the bag, spawned onto the table, and then examined in detail
    --     properties of objects in containers (bags, decks, stacks) do not match the properties of objects spawned into the physics engine
    --     container.getObjects() does not actually return a list of objects
    --         Instead, it only has a short list of inconsistent information about each contained object
    --         spawned object properties: type = "Deck", name = "Deck",            getName() = "hello_world"
    --         contained object info:     type = nil,    name = "hello_world", and getName() is not callable
    -- Finally, spawning the object takes non-trivial real time, so we do this one object at a time, until the bag is empty
    --     one object is spawned and assigned a callback function to execute when finished spawning
    --     the callback function executes, and finishes by calling this function again to sort the next object

    -- identify end-point bag to sort (possibly self)
    bag = bag_sort_queue[#bag_sort_queue]

    -- handle the special case where a deck is dissolved into a single card
    --     decks cannot exist with less than two contained objects
    --     taking out the second to last contained object will result in the deck being destroyed
    --     in its place the last remaining object in the deck will be spawned
    remainder = bag.remainder
    if remainder ~= nil then
        bag_sort_queue[#bag_sort_queue] = nil

        -- wait for object to finish spawning before moving the object
        -- sort_object handles recursion back to this function when it finishes
        Wait.condition(partial(sort_object, remainder),
                       function() return not remainder.spawning end)
        return
    end

    bag_contents = bag.getObjects()

    -- handle empty bags
    if #bag_contents == 0 then
        -- unlock currently_sorting mutex when finished sorting master sorting-bag
        if bag.guid == self.guid then
            currently_sorting = false
            return
        
        -- otherwise move the sub-bag out of the way, and continue parent bag sort
        else
            -- empty bags can either be moved to a trash collection location, or destroyed
            -- if moved to a trash location, then we must wait for the bag to fall to avoid physics explosions
            --     when multiple bags are moved into the same position in quick succession
            -- Therefore, I've opted to destroy the empty bags, to keep the sorter snappy-fast
            bag.destruct()  -- destroy empty bag
            bag_sort_queue[#bag_sort_queue] = nil
            sort_lowest_bag()
            return
        end

    end

    for _, contained_object in pairs(bag_contents) do
        -- take an object out of hte bag and spawn it into physical space
        spawned_object = bag.takeObject({
            guid              = contained_object.guid,
            position          = relative_position(bag, 0, 1, 0),
            callback_function = finish_sorting_spawned_object,  -- callback executes only after the object has finished spawning
            smooth            = false,  -- instant movement
        })

        -- Now wait until the object is spawned, until it executes the callback_function, which finishes and then calls this function again
        break
    end
end


function finish_sorting_spawned_object(object)
    -- callback executes after object has finished spawning
    -- determines whether object should be directly sorted (eg card) or recursively sorted (bag/deck)

    if object.type == 'Deck' or object.type == 'Bag' then
        -- queue bag, and go back to top via recursion
        table.insert(bag_sort_queue, object)
        sort_lowest_bag()
    else
        sort_object(object)
    end
end


function sort_object(object)
    -- moves an object from temporary storage space to a location on the table, according to the object's properties
    -- instructs the parent bag to continue sorting when temporary storage is available again
    -- Uses the following fields to sort, in priority order
    --    name
    --    description
    -- destination is always relative to master sorting-bag

    sorting_key = object.getName() .. object.getDescription()

    -- assign destination in physical space
    destination_index = sorting_locations[sorting_key]
        
    if destination_index == nil then
        -- determine next location by considering assigned locations
        -- cannot use #sorting_locations since it is not a true len operation on tables with non-numeric keys
        --     see https://www.lua.org/manual/5.3/manual.html#3.4.7
        farthest_assigned_index = -1
        for _, index in pairs(sorting_locations) do
            if index > farthest_assigned_index then
                farthest_assigned_index = index
            end
        end

        destination_index = farthest_assigned_index + 1
        sorting_locations[sorting_key] = destination_index
    end

    -- move object to designated location
    destination = relative_position(self, 1, destination_index, 1)
    object.setPosition(destination)  -- instant movement

    -- instruct the lowest bag to sort its next object
    sort_lowest_bag()
end
