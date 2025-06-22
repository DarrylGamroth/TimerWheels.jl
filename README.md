# TimerWheels.jl

A Julia implementation of a deadline timer wheel data structure for efficient timer scheduling and expiration handling.

## Overview

TimerWheels.jl provides a `DeadlineTimerWheel` that allows you to:
- Schedule timers with specific deadlines
- Poll for expired timers efficiently
- Cancel scheduled timers
- Handle timer expiration with custom callbacks

The implementation is based on the timer wheel algorithm described in "Hashed and Hierarchical Timing Wheels" by Varghese and Lauck, and follows the design of the Agrona library's DeadlineTimerWheel.

## Installation

```julia
using Pkg
Pkg.add("TimerWheels.jl")
```

## Usage

### Basic Example

```julia
using TimerWheels

# Create a timer wheel
# start_time=1000, tick_resolution=8, ticks_per_wheel=8
wheel = DeadlineTimerWheel(1000, 8, 8)

# Schedule a timer to expire at time 1016 (tick 2)
timer_id = schedule_timer!(wheel, 1016)

# Create a handler for expired timers
handler = TimerHandler(nothing) do client, now, timer_id
    println("Timer $timer_id expired at time $now")
    return true  # Return true to consume the timer
end

# Poll for expired timers at current time
# The timer at 1016 should expire when we poll at 1016 or later
expired_count = poll(wheel, handler, 1020)

println("$expired_count timers expired")
```

## Important: Polling Frequency Requirements

**For correct timer expiration, applications must poll at intervals ≤ `tick_resolution`.** Large time gaps between polls may cause timers to be missed, particularly those scheduled far in the future that span multiple wheel rotations.

This implementation is optimized for high-frequency polling applications (e.g., nanosecond-resolution timers polled every microsecond). The algorithm will assert if polling is too infrequent to ensure correctness.

**Recommended:** Poll every `tick_resolution` time units or faster for optimal performance and correctness.

### Timer Handler

Timer handlers receive three arguments:
- `client`: User-provided client data
- `now`: Current time when the timer expired
- `timer_id`: ID of the expired timer

Return `true` to consume the timer, or `false` to keep it active and stop polling.

### API Reference

#### Constructor
- `DeadlineTimerWheel(start_time, tick_resolution, ticks_per_wheel, initial_tick_allocation=16)`

#### Timer Operations
- `schedule_timer!(wheel, deadline)` - Schedule a timer, returns timer ID
- `cancel_timer!(wheel, timer_id)` - Cancel a timer, returns true if successful
- `poll(wheel, handler, now, expiry_limit=typemax(Int64))` - Poll for expired timers

#### Utility Functions
- `timer_count(wheel)` - Number of active timers
- `current_tick_time(wheel)` - Current tick time
- `clear!(wheel)` - Remove all timers

#### Timer Information
- `deadline(wheel, timer_id)` - Get deadline for a timer
- `tick_resolution(wheel)` - Get tick resolution
- `ticks_per_wheel(wheel)` - Get number of ticks per wheel

## Requirements

- Julia 1.6 or later
- FunctionWrappers.jl

## License

This project is licensed under the MIT License.
