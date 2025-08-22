using Printf
using Test
using TimerWheels

# Include compatible test files
include("test_timer_handler.jl")
include("test_integration.jl")
include("test_edge_cases.jl")
include("test_java_compatibility.jl")

# Note: test_performance.jl and test_realtime_poll.jl are currently disabled
# as they test behaviors specific to the old poll algorithm that are not
# compatible with the Java Agrona poll algorithm implementation
