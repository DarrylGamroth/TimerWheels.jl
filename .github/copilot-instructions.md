# TimerWheels.jl

TimerWheels.jl is a Julia package implementing a deadline timer wheel data structure for efficient timer scheduling and expiration handling. It provides high-performance timer management optimized for high-frequency polling applications (e.g., nanosecond-resolution timers polled every microsecond).

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

## Working Effectively

- Bootstrap, develop, and test the repository:
  - `julia --version` (verify Julia 1.6+ is available)
  - `julia -e 'using Pkg; Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/DarrylGamroth/PackageRegistry.git"))'` -- adds custom registry, takes ~2 seconds if already exists, ~15 seconds for first time
  - `julia -e 'using Pkg; Pkg.Registry.add(Pkg.RegistrySpec(url="https://github.com/JuliaRegistries/General.git"))'` -- adds General registry, takes ~60 seconds if already exists, ~90 seconds for first time
  - `julia -e 'using Pkg; Pkg.develop(PackageSpec(path="."))'` -- develop package locally, takes ~2 seconds
  - `julia -e 'using Pkg; Pkg.instantiate()'` -- instantiate dependencies, takes ~2 seconds
- Test the package:
  - `julia --project=. test/runtests.jl` -- run full test suite, takes ~5 seconds. NEVER CANCEL: Wait for completion.
  - Tests include: timer handler tests, integration tests, edge cases, performance benchmarks, real-time polling tests
  - Individual test files MUST be run through runtests.jl (they depend on imports from runtests.jl)
  - Performance tests may occasionally fail due to timing variations - this is normal; re-run if needed
- Format code (optional):
  - `julia -e 'using Pkg; Pkg.add("JuliaFormatter"); using JuliaFormatter; format("."; verbose=true)'` -- format all Julia files, takes ~5 seconds for formatting, ~45 seconds total for first run (including package installation)
  - Remove formatter after use: `julia -e 'using Pkg; Pkg.rm("JuliaFormatter")'`

## Validation

- Always manually validate any changes by testing the basic API:
  ```julia
  using TimerWheels
  wheel = DeadlineTimerWheel(1000, 8, 8)
  timer_id = schedule_timer!(wheel, 1016)
  expired_count = poll(wheel, 1020, nothing) do client, now, timer_id
      println("Timer $timer_id expired at time $now")
      return true
  end
  ```
- ALWAYS run the full test suite after making changes: `julia --project=. test/runtests.jl`
- Do NOT run individual test files directly - they depend on imports from runtests.jl
- Performance benchmarks run automatically with tests and show timing for 10,000 timer operations
- Always validate timer scheduling, cancellation, and polling scenarios work correctly
- Test scenarios should verify: timer expiration at correct times, handler callbacks, poll limits, iteration over active timers

## Common Tasks

The following are outputs from frequently run commands. Reference them instead of viewing, searching, or running bash commands to save time.

### Repository Structure
```
.
├── .github/
│   └── workflows/
│       └── ci.yml          # CI configuration (30 min timeout)
├── src/
│   ├── TimerWheels.jl      # Main module file
│   └── deadlinetimerwheel.jl  # Core implementation
├── test/
│   ├── runtests.jl         # Test runner
│   ├── test_timer_handler.jl
│   ├── test_integration.jl
│   ├── test_edge_cases.jl
│   ├── test_performance.jl
│   └── test_realtime_poll.jl
├── Project.toml            # Package metadata
└── README.md
```

### Project.toml
```toml
name = "TimerWheels"
uuid = "aebde43d-366d-4353-b020-04442e269197"
authors = ["Darryl Gamroth <dgamroth@rubus.ca>"]
version = "0.2.1"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
Printf = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[targets]
test = ["Test", "Printf"]
```

### Main API (from src/deadlinetimerwheel.jl)
Key exports:
- `DeadlineTimerWheel(start_time, tick_resolution, ticks_per_wheel, initial_tick_allocation=16)`
- `schedule_timer!(wheel, deadline)` -> timer_id
- `cancel_timer!(wheel, timer_id)` -> success
- `poll(callback, wheel, now, client=nothing; expiry_limit=typemax(Int64))` -> expired_count
- `timer_count(wheel)`, `deadline(wheel, timer_id)`, `clear!(wheel)`

### Typical Test Output
```
Test Summary:       | Pass  Total  Time
Poll Callback Tests |   20     20  0.5s
Test Summary:     | Pass  Total  Time
Integration Tests |  123    123  0.5s
Test Summary:                   | Pass  Total  Time
Edge Cases and Error Conditions |   41     41  0.6s

================================================================================
TIMER WHEEL PERFORMANCE BENCHMARKS
================================================================================
Test Size: 10000 timers (subset tests: 1000)
--------------------------------------------------------------------------------
Operation                 |    Count | Total Time | Per Item
--------------------------------------------------------------------------------
Schedule                  |    10000 |      8.292 ms |    829.2 ns
Cancel                    |     5000 |      3.989 ms |    797.8 ns
Poll (large jump)         |     1000 |     42.346 ms |  42346.0 ns
...
Test Summary:     | Pass  Total  Time
Performance Tests |   27     27  1.4s
Test Summary:              | Pass  Total  Time
Real-Time Poll Index Tests |   94     94  0.4s
```

## Important Usage Notes

- **No Build Step Required**: Julia is interpreted, no compilation needed
- **Polling Frequency Critical**: Applications must poll at intervals ≤ `tick_resolution` for correct timer expiration
- **Power of 2 Requirements**: tick_resolution and ticks_per_wheel must be powers of 2
- **Thread Safety**: Not threadsafe - use appropriate synchronization if needed
- **Performance Optimized**: Designed for high-frequency polling (nanosecond timers, microsecond polling)
- **Registry Dependencies**: Requires both DarrylGamroth custom registry and General registry
- **Cross-Platform**: Works on Linux, Windows, macOS with Julia 1.6+

## Error Handling

- Parameter validation errors: tick_resolution and ticks_per_wheel must be powers of 2
- Timer not found errors: cancel_timer! returns false for non-existent timers
- Handler exceptions: poll() propagates handler exceptions, use try-catch in handlers
- Memory expansion: wheel automatically grows tick arrays when needed

## Key Implementation Details

- Timer IDs are 64-bit integers combining tick index and array position
- Timers in same tick may expire out of order (coarse resolution)
- `expiry_limit` parameter enables bounded execution time per poll
- Wheel maintains `poll_index` state to resume processing after hitting limits
- Iterator support allows examining active timers without expiring them