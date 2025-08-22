export DeadlineTimerWheel,
    tick_resolution,
    ticks_per_wheel,
    start_time,
    timer_count,
    reset_start_time!,
    current_tick_time,
    clear!,
    deadline,
    schedule_timer!,
    cancel_timer!,
    poll

"""
Represents a deadline not set in the wheel.
"""
const NULL_DEADLINE::Int64 = typemax(Int64)
const INITIAL_TICK_ALLOCATION = 16

"""
    DeadlineTimerWheel

Timer Wheel for timers scheduled to expire on a deadline (NOT thread safe).

Based on netty's HashedTimerWheel, which is based on George Varghese and
Tony Lauck's paper, 'Hashed and Hierarchical Timing Wheels: data structures
to efficiently implement a timer facility'. More comprehensive slides are located
[here](http://www.cse.wustl.edu/~cdgill/courses/cs6874/TimingWheels.ppt).

Wheel is backed by arrays. Timer cancellation is O(1). Timer scheduling might be slightly
longer if a lot of timers are in the same tick or spoke. The underlying tick is contained in
an array. That array grows when needed, but does not shrink.

## Important Usage Notes

**⚠️ Polling Frequency:** For correct timer expiration, applications should poll at intervals
≤ `tick_resolution`. Large time jumps between polls may cause some timers to be missed,
especially timers scheduled far in the future that span multiple wheel rotations.

**📈 Performance:** This implementation prioritizes performance for high-frequency polling
applications (e.g., nanosecond-resolution timers polled every microsecond). Frequent
polling ensures both correctness and optimal performance.

**⏱️ Real-Time Systems:** The `expiry_limit` parameter enables bounded execution time
per poll call. The wheel maintains state (`poll_index`) to resume processing exactly
where it left off, ensuring no timers are missed even when hitting expiry limits.

## Caveats

Timers that expire in the same tick are not ordered with one another. As ticks are
fairly coarse resolution normally, this means that some timers may expire out of order.

**Note:** Not threadsafe.

## Fields
- `start_time::Int64`: The start time for the wheel from which it advances
- `current_tick::Int64`: Current tick of the wheel
- `timer_count::Int64`: Number of active timers
- `ticks_per_wheel::Int32`: Number of ticks (or spokes) per wheel (must be power of 2)
- `tick_mask::Int32`: Mask for tick indexing
- `resolution_bits_to_shift::Int32`: Number of bits to shift for resolution
- `tick_resolution::Int64`: Resolution of a tick in time units
- `tick_allocation::Int32`: Space allocated per tick of the wheel
- `allocation_bits_to_shift::Int32`: Number of bits to shift for allocation
- `poll_index::Int32`: Current polling index within a tick (for resuming across poll calls)
- `wheel::Vector{Int64}`: The wheel array storing timer deadlines
"""
mutable struct DeadlineTimerWheel
    start_time::Int64
    current_tick::Int64
    timer_count::Int64
    const ticks_per_wheel::Int32
    const tick_mask::Int32
    const resolution_bits_to_shift::Int32
    const tick_resolution::Int64
    tick_allocation::Int32
    allocation_bits_to_shift::Int32
    poll_index::Int32
    wheel::Vector{Int64}
end

"""
    DeadlineTimerWheel(start_time, tick_resolution, ticks_per_wheel, initial_tick_allocation=16)

Construct timer wheel and configure timing with provided initial allocation.

# Arguments
- `start_time::Int64`: Start time for the wheel
- `tick_resolution::Int64`: Resolution for the wheel, i.e. how many time units per tick (must be power of 2)
- `ticks_per_wheel::Integer`: Number of ticks or spokes for the wheel (must be power of 2)
- `initial_tick_allocation::Integer`: Space allocated per tick of the wheel (must be power of 2)

# Returns
A new `DeadlineTimerWheel` instance

# Throws
- `ArgumentError`: If any parameter is not a power of 2 where required
"""

function DeadlineTimerWheel(
    start_time::Int64,
    tick_resolution::Int64,
    ticks_per_wheel::Integer,
    initial_tick_allocation::Integer = INITIAL_TICK_ALLOCATION,
)

    check_ticks_per_wheel(ticks_per_wheel)
    check_resolution(tick_resolution)
    check_initial_tick_allocation(initial_tick_allocation)

    resolution_bits_to_shift = trailing_zeros(tick_resolution)
    allocation_bits_to_shift = trailing_zeros(initial_tick_allocation)
    tick_mask = ticks_per_wheel - 1

    wheel = Vector{Int64}(undef, ticks_per_wheel * initial_tick_allocation)
    fill!(wheel, NULL_DEADLINE)

    return DeadlineTimerWheel(
        start_time,
        0,
        0,
        ticks_per_wheel,
        tick_mask,
        resolution_bits_to_shift,
        tick_resolution,
        initial_tick_allocation,
        allocation_bits_to_shift,
        0,
        wheel,
    )
end

"""
    tick_resolution(wheel::DeadlineTimerWheel) -> Int64

Resolution of a tick of the wheel in time units.

# Returns
Resolution of a tick of the wheel in time units.
"""
tick_resolution(t::DeadlineTimerWheel) = t.tick_resolution

"""
    ticks_per_wheel(wheel::DeadlineTimerWheel) -> Int32

The number of ticks, or spokes, per wheel.

# Returns
Number of ticks, or spokes, per wheel.
"""
ticks_per_wheel(t::DeadlineTimerWheel) = t.ticks_per_wheel

"""
    start_time(wheel::DeadlineTimerWheel) -> Int64

The start time tick for the wheel from which it advances.

# Returns
Start time tick for the wheel from which it advances.
"""
start_time(t::DeadlineTimerWheel) = t.start_time

"""
    timer_count(wheel::DeadlineTimerWheel) -> Int64

Number of active timers.

# Returns
Number of currently scheduled timers.
"""
timer_count(t::DeadlineTimerWheel) = t.timer_count

"""
    reset_start_time!(wheel::DeadlineTimerWheel, start_time::Int64)

Reset the start time of the wheel.

# Arguments
- `start_time::Int64`: New start time to set the wheel to

# Throws
- `ArgumentError`: If wheel has any scheduled timers
"""
function reset_start_time!(t::DeadlineTimerWheel, start_time::Int64)
    if t.timer_count > 0
        throw(ArgumentError("Cannot reset start time while there are pending timers"))
    end

    t.start_time = start_time
    t.current_tick = 0
    t.poll_index = 0
end

"""
    current_tick_time(wheel::DeadlineTimerWheel) -> Int64

Time of current tick of the wheel in time units.

# Returns
Time of the current tick of the wheel in time units.
"""
current_tick_time(t::DeadlineTimerWheel) =
    ((t.current_tick + 1) << t.resolution_bits_to_shift) + t.start_time

"""
    clear!(wheel::DeadlineTimerWheel)

Clear out all scheduled timers in the wheel.
"""
function clear!(t::DeadlineTimerWheel)
    fill!(t.wheel, NULL_DEADLINE)
    t.timer_count = 0
end

"""
    schedule_timer!(wheel::DeadlineTimerWheel, deadline) -> Int64

Schedule a timer for a given absolute time as a deadline in time units. A timer ID will be assigned
and returned for future reference.

# Arguments
- `deadline`: Absolute time after which the timer should expire

# Returns
Timer ID assigned for the scheduled timer
"""
function schedule_timer!(t::DeadlineTimerWheel, deadline)
    deadline_tick =
        max((deadline - t.start_time) >> t.resolution_bits_to_shift, t.current_tick)
    spoke_index = deadline_tick & t.tick_mask
    tick_start_index = (spoke_index << t.allocation_bits_to_shift) + 1

    for i = 0:(t.tick_allocation-1)
        index = tick_start_index + i
        if t.wheel[index] == NULL_DEADLINE
            t.wheel[index] = deadline
            t.timer_count += 1
            return timer_id_for_slot(spoke_index, i)
        end
    end

    increase_capacity!(t, deadline, spoke_index)
end

"""
    cancel_timer!(wheel::DeadlineTimerWheel, timer_id) -> Bool

Cancel a previously scheduled timer.

# Arguments
- `timer_id`: ID of the timer to cancel

# Returns
`true` if successful, otherwise `false` if the timer ID did not exist
"""
function cancel_timer!(t::DeadlineTimerWheel, timer_id)
    spoke_index = tick_for_timer_id(timer_id)
    tick_index = index_in_tick_array(timer_id)
    wheel_index = (spoke_index << t.allocation_bits_to_shift) + tick_index + 1

    if spoke_index < t.ticks_per_wheel
        if tick_index < t.tick_allocation && t.wheel[wheel_index] != NULL_DEADLINE
            t.wheel[wheel_index] = NULL_DEADLINE
            t.timer_count -= 1
            return true
        end
    end
    return false
end

"""
    poll(callback, wheel::DeadlineTimerWheel, now::Int64, clientd=nothing; expiry_limit::Int64=typemax(Int64)) -> Int64

Poll for timers expired by the deadline passing.

This implementation uses an incremental algorithm that processes timers slot-by-slot,
maintaining state (`poll_index`) to resume exactly where it left off across poll calls.
This ensures bounded execution time when using `expiry_limit`, making it suitable for
real-time systems with strict timing requirements.

**CRITICAL:** For correctness with timers that span multiple wheel rotations,
**applications MUST poll frequently** - ideally at intervals ≤ `tick_resolution`.
Large time jumps between polls (greater than `ticks_per_wheel * tick_resolution`)
may cause some timers to be missed.

**Real-Time Usage:** Use `expiry_limit` to bound the number of timers processed per
poll call. The wheel will automatically resume from where it left off on the next
poll, ensuring no timers are missed while maintaining predictable execution time.

# Arguments
- `callback`: Function to call for each expired timer with signature `(clientd, now, timer_id) -> Bool`
- `wheel::DeadlineTimerWheel`: The timer wheel to poll
- `now::Int64`: Current time to compare deadlines against
- `clientd`: Client data to pass to the callback function (default: nothing)
- `expiry_limit::Int64`: Maximum number of timers to process in one poll operation (default: no limit)

# Returns
Count of expired timers as a result of this poll operation

# Callback Function
The callback function will be called for each expired timer with:
- `clientd`: User-provided client data
- `now`: Current time when the timer expired
- `timer_id`: ID of the expired timer

The callback should return `true` to consume the timer, or `false` to keep the timer active and abort further polling.

# Example
```julia
expired_timers = Int64[]
count = poll(wheel, now, expired_timers) do client, now, timer_id
    push!(client, timer_id)
    return true
end
```
"""
function poll(
    callback,
    t::DeadlineTimerWheel,
    now::Int64,
    clientd = nothing;
    expiry_limit::Int64 = typemax(Int64),
)

    timers_expired = 0

    # Calculate the target tick based on current time
    target_tick = (now - t.start_time) >> t.resolution_bits_to_shift

    # Ensure we don't go backwards in time
    target_tick = max(target_tick, t.current_tick)

    # POLLING FREQUENCY CHECK: Detect if we're polling too slowly
    # This check is important even with no timers - validates polling pattern
    tick_jump = target_tick - t.current_tick
    max_safe_jump = t.ticks_per_wheel

    if tick_jump > max_safe_jump
        @warn "Polling too slowly: jumped $tick_jump ticks (max safe: $max_safe_jump). " *
              "Some timers may have been missed. Resetting to current time and continuing." *
              " Poll more frequently to avoid this issue!"

        # Automatic recovery: reset current_tick to target_tick and return 0
        t.current_tick = target_tick
        t.poll_index = 0
        return 0
    end

    # Early exit if no timers to process
    if t.timer_count <= 0
        # Advance time but no timers to process
        t.current_tick = target_tick
        t.poll_index = 0
        return 0
    end

    # REAL-TIME FRIENDLY ALGORITHM WITH poll_index
    # Process timers incrementally, respecting expiry_limit for bounded execution time
    while t.current_tick <= target_tick && timers_expired < expiry_limit
        spoke_index = t.current_tick & t.tick_mask

        # Resume processing from poll_index within the current tick
        for slot_index = t.poll_index:(t.tick_allocation-1)
            if timers_expired >= expiry_limit
                # Hit expiry limit - save our position and return
                t.poll_index = slot_index
                return timers_expired
            end

            wheel_index = (spoke_index << t.allocation_bits_to_shift) + slot_index + 1
            deadline = t.wheel[wheel_index]

            if deadline != NULL_DEADLINE && now >= deadline
                t.wheel[wheel_index] = NULL_DEADLINE
                t.timer_count -= 1
                timers_expired += 1

                timer_id = timer_id_for_slot(spoke_index, slot_index)
                if !callback(clientd, now, timer_id)
                    # Callback rejected the timer expiry, restore it and stop processing
                    t.wheel[wheel_index] = deadline
                    t.timer_count += 1
                    t.poll_index = slot_index + 1
                    return timers_expired - 1
                end
            end
        end

        # Finished processing all slots in current tick - advance to next tick
        t.current_tick += 1
        t.poll_index = 0
    end

    return timers_expired
end

"""
    deadline(wheel::DeadlineTimerWheel, timer_id) -> Int64

Get the deadline for the given timer ID.

# Arguments
- `timer_id`: ID of the timer to return the deadline of

# Returns
Deadline for the given timer ID or [`NULL_DEADLINE`](@ref) if timer ID is not scheduled
"""
function deadline(t::DeadlineTimerWheel, timer_id)
    spoke_index = tick_for_timer_id(timer_id)
    tick_index = index_in_tick_array(timer_id)
    wheel_index = (spoke_index << t.allocation_bits_to_shift) + tick_index + 1

    if spoke_index < t.ticks_per_wheel && tick_index < t.tick_allocation
        return t.wheel[wheel_index]
    end
    return NULL_DEADLINE
end

"""
    increase_capacity!(wheel::DeadlineTimerWheel, deadline, spoke_index) -> Int64

Internal function to increase the capacity of the timer wheel when a tick becomes full.
This doubles the allocation per tick and redistributes existing timers.

# Arguments
- `deadline`: Deadline of the timer that triggered the expansion
- `spoke_index`: Index of the spoke that needs more capacity

# Returns
Timer ID for the newly scheduled timer

# Throws
- `ArgumentError`: If maximum capacity is reached
"""
function increase_capacity!(t::DeadlineTimerWheel, deadline, spoke_index)
    new_tick_allocation = t.tick_allocation << 1
    new_allocation_bits_to_shift = trailing_zeros(new_tick_allocation)
    new_capacity = t.ticks_per_wheel * new_tick_allocation
    if new_capacity > (typemax(typeof(t.tick_allocation)) + 1)
        throw(
            ArgumentError(
                "Maximum capacity reached at tick_allocation=$(t.tick_allocation)",
            ),
        )
    end

    new_wheel = Vector{Int64}(undef, t.ticks_per_wheel * new_tick_allocation)
    fill!(new_wheel, NULL_DEADLINE)

    for i = 0:(t.ticks_per_wheel-1)
        old_tick_start_index = (i << t.allocation_bits_to_shift) + 1
        new_tick_start_index = (i << new_allocation_bits_to_shift) + 1
        new_wheel[new_tick_start_index:(new_tick_start_index+t.tick_allocation-1)] .=
            t.wheel[old_tick_start_index:(old_tick_start_index+t.tick_allocation-1)]
    end

    new_wheel[(spoke_index<<new_allocation_bits_to_shift)+t.tick_allocation+1] = deadline
    timer_id = timer_id_for_slot(spoke_index, t.tick_allocation)
    t.timer_count += 1

    t.tick_allocation = new_tick_allocation
    t.allocation_bits_to_shift = new_allocation_bits_to_shift
    t.wheel = new_wheel

    return timer_id
end

"""
    timer_id_for_slot(tick_on_wheel, tick_array_index) -> Int64

Generate a timer ID from wheel position coordinates.

# Arguments
- `tick_on_wheel`: Spoke index on the wheel
- `tick_array_index`: Index within the tick array

# Returns
Unique timer ID encoding the position
"""
timer_id_for_slot(tick_on_wheel, tick_array_index) =
    (Int64(tick_on_wheel) << 32) | (Int64(tick_array_index & 0xFFFFFFFF))

"""
    tick_for_timer_id(timer_id) -> Int64

Extract the tick (spoke) index from a timer ID.

# Arguments
- `timer_id`: Timer ID to decode

# Returns
Tick (spoke) index on the wheel
"""
tick_for_timer_id(timer_id) = timer_id >> 32

"""
    index_in_tick_array(timer_id) -> Int64

Extract the index within the tick array from a timer ID.

# Arguments
- `timer_id`: Timer ID to decode

# Returns
Index within the tick array
"""
index_in_tick_array(timer_id) = timer_id & 0xFFFFFFFF

"""
    check_ticks_per_wheel(ticks_per_wheel)

Validate that ticks per wheel is a power of 2.

# Throws
- `ArgumentError`: If ticks per wheel is not a power of 2
"""
function check_ticks_per_wheel(ticks_per_wheel)
    ispow2(ticks_per_wheel) ||
        throw(ArgumentError("ticks per wheel must be a power of 2: $ticks_per_wheel"))
end

"""
    check_resolution(tick_resolution)

Validate that tick resolution is a power of 2.

# Throws
- `ArgumentError`: If tick resolution is not a power of 2
"""
function check_resolution(tick_resolution)
    ispow2(tick_resolution) ||
        throw(ArgumentError("tick resolution must be a power of 2: $tick_resolution"))
end

"""
    check_initial_tick_allocation(tick_allocation)

Validate that initial tick allocation is a power of 2.

# Throws
- `ArgumentError`: If tick allocation is not a power of 2
"""
function check_initial_tick_allocation(tick_allocation)
    ispow2(tick_allocation) ||
        throw(ArgumentError("tick allocation must be a power of 2: $tick_allocation"))
end

"""
    Base.iterate(wheel::DeadlineTimerWheel, state=nothing)

Iterator implementation for DeadlineTimerWheel.

Allows iteration over all active timers in the wheel without expiring them.
Each iteration yields a tuple of `(deadline, timer_id)`.

# Example
```julia
wheel = DeadlineTimerWheel(1000, 10, 8)
schedule_timer!(wheel, 1050)
for (deadline, timer_id) in wheel
    println("Timer \$timer_id expires at \$deadline")
end
```
"""
function Base.iterate(t::DeadlineTimerWheel, state = nothing)
    # Initial case: start from the beginning
    if state === nothing
        # Return nothing if no timers
        if t.timer_count == 0
            return nothing
        end

        # Start from index 1
        index_to_start = 1
        timers_seen = 0
    else
        # Unpack state
        index_to_start, timers_seen = state

        # Return nothing if we've seen all timers
        if timers_seen >= t.timer_count
            return nothing
        end
    end

    # Find next non-NULL_DEADLINE
    for index = index_to_start:length(t.wheel)
        deadline = t.wheel[index]
        if deadline != NULL_DEADLINE
            i = index - 1
            spoke_index = i >> t.allocation_bits_to_shift
            slot_index = i & ((1 << t.allocation_bits_to_shift) - 1)
            timer_id = timer_id_for_slot(spoke_index, slot_index)
            return ((deadline, timer_id), (index + 1, timers_seen + 1))
        end
    end

    return nothing
end

Base.length(t::DeadlineTimerWheel) = t.timer_count
Base.eltype(::Type{DeadlineTimerWheel}) = Tuple{Int64,Int64}
