# TimerWheels.jl

[![CI](https://github.com/DarrylGamroth/TimerWheels.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/DarrylGamroth/TimerWheels.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/DarrylGamroth/TimerWheels.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/DarrylGamroth/TimerWheels.jl)

A Julia implementation of a deadline timer wheel data structure for efficient timer scheduling and expiration handling, **compatible with Java Agrona's DeadlineTimerWheel implementation**.

## Overview

TimerWheels.jl provides a `DeadlineTimerWheel` that allows you to:
- Schedule timers with specific deadlines
- Poll for expired timers efficiently using Java Agrona-compatible algorithm
- Cancel scheduled timers
- Handle timer expiration with custom callbacks

The implementation follows the Java Agrona `DeadlineTimerWheel` design with identical polling behavior, ensuring compatibility and performance characteristics that match the widely-used Java implementation.

## Key Features

- **Java Agrona Compatibility**: Poll algorithm matches Java Agrona's incremental tick-by-tick processing
- **Bounded Execution Time**: Each poll call processes a limited number of timers for predictable performance
- **State Preservation**: Poll state is maintained across calls to resume exactly where the previous poll left off
- **High Performance**: Optimized for high-frequency polling applications

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

# Poll for expired timers - Java Agrona compatible incremental polling
control_timestamp = 1000
while timer_count(wheel) > 0
    expired_count = poll(wheel, handler, control_timestamp)
    control_timestamp += tick_resolution(wheel)  # Advance by one tick
end
```

## Important: Java Agrona Compatible Polling

**This implementation uses the Java Agrona polling algorithm**, which differs from traditional timer wheel implementations:

### Incremental Processing
- **One tick per poll**: Each poll call processes only the current tick, not multiple ticks
- **Frequent polling required**: Applications should poll every `tick_resolution` time units
- **State maintained**: Poll position (`poll_index`) is preserved across calls for bounded execution

### Recommended Usage Pattern
```julia
# Correct: Incremental polling (Java Agrona style)
control_timestamp = start_time
while running
    poll(wheel, handler, control_timestamp)
    control_timestamp += tick_resolution(wheel)
    # ... other application logic
end
```

### Breaking Change from Traditional Approach
Unlike traditional timer wheels that process all expired timers in a single large time jump, this implementation requires incremental polling for correctness. **Applications must be updated to poll frequently** to ensure timers expire correctly.

## Performance Characteristics

This implementation provides the same performance characteristics as Java Agrona:

- **Bounded poll time**: Each poll call has predictable execution time
- **Efficient for high-frequency polling**: Optimized for microsecond-resolution polling
- **Scalable timer count**: Performance remains consistent with large numbers of timers
- **Memory efficient**: Dynamic expansion only when needed

## Timer Handler

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
- `poll(wheel, handler, now, expiry_limit=typemax(Int64))` - Poll for expired timers (Java Agrona compatible)

#### Utility Functions
- `timer_count(wheel)` - Number of active timers
- `current_tick_time(wheel)` - Current tick time
- `current_tick_time!(wheel, now)` - Manually advance wheel time (matches Java API)
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
