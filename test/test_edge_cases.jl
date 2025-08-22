@testset "Edge Cases and Error Conditions" begin

    @testset "Boundary Value Testing" begin
        @testset "Minimum Values" begin
            # Smallest possible configuration
            wheel = DeadlineTimerWheel(0, 1, 2, 1)
            @test timer_count(wheel) == 0

            # Schedule at minimum time
            timer_id = schedule_timer!(wheel, 0)
            @test timer_count(wheel) == 1
            @test deadline(wheel, timer_id) == 0
        end

        @testset "Large Values" begin
            # Large time values
            large_start = Int64(typemax(Int32))
            wheel = DeadlineTimerWheel(large_start, 1024, 1024)

            # Schedule at very large deadline
            large_deadline = large_start + 1000000
            timer_id = schedule_timer!(wheel, large_deadline)
            @test deadline(wheel, timer_id) == large_deadline
        end

        @testset "Edge Timer IDs" begin
            wheel = DeadlineTimerWheel(0, 1, 4)

            # Test behavior with invalid timer IDs
            @test cancel_timer!(wheel, 0) == false
            @test cancel_timer!(wheel, -1) == false
            @test cancel_timer!(wheel, typemax(Int64)) == false
            @test deadline(wheel, 0) == TimerWheels.NULL_DEADLINE
            @test deadline(wheel, -1) == TimerWheels.NULL_DEADLINE
        end
    end

    @testset "Memory Exhaustion Simulation" begin
        @testset "Maximum Capacity Limits" begin
            # Use small wheel to quickly hit capacity limits
            wheel = DeadlineTimerWheel(0, 1, 2, 2)

            # Fill up capacity gradually
            timer_ids = Int64[]

            # This should work for reasonable numbers
            for i = 1:10
                try
                    timer_id = schedule_timer!(wheel, 10)  # Same deadline to fill one spoke
                    push!(timer_ids, timer_id)
                catch e
                    if e isa ArgumentError && contains(string(e), "Maximum capacity")
                        break
                    else
                        rethrow(e)
                    end
                end
            end

            # Should have scheduled at least some timers
            @test length(timer_ids) > 0
            @test timer_count(wheel) == length(timer_ids)
        end
    end

    @testset "Concurrent Access Patterns" begin
        @testset "Interleaved Operations" begin
            wheel = DeadlineTimerWheel(1000, 8, 16)

            timer_ids = Int64[]

            # Interleave scheduling, cancelling, and polling
            for i = 1:20
                # Schedule
                if i % 3 == 1
                    timer_id = schedule_timer!(wheel, 1000 + i*10)
                    push!(timer_ids, timer_id)
                end

                # Cancel
                if i % 3 == 2 && !isempty(timer_ids)
                    timer_to_cancel = pop!(timer_ids)
                    cancel_timer!(wheel, timer_to_cancel)
                end

                # Poll
                if i % 3 == 0
                    poll(wheel, 1000 + i*10, nothing) do client, now, timer_id
                        return true
                    end
                end
            end

            # Wheel should remain in valid state
            @test timer_count(wheel) >= 0
        end
    end

    @testset "Handler Error Conditions" begin
        @testset "Handler Exceptions" begin
            wheel = DeadlineTimerWheel(1000, 8, 8)

            # Schedule a timer for the first tick
            timer_id = schedule_timer!(wheel, 1000)  # Will be placed in tick 0

            # Poll at time that will advance to next tick and expire the timer
            @test_throws ErrorException poll(wheel, 1008, nothing) do client, now, timer_id
                throw(ErrorException("Handler error"))
            end
        end

        @testset "Handler State Corruption" begin
            wheel = DeadlineTimerWheel(1000, 8, 8)

            timer_id = schedule_timer!(wheel, 1000)  # Will be placed in tick 0
            initial_count = timer_count(wheel)

            # Poll at time that will expire the timer
            poll(wheel, 1008, wheel) do client, now, timer_id
                # Try to schedule another timer during callback
                schedule_timer!(client, now + 100)
                return true
            end

            # Timer count should have changed (one expired, one added)
            @test timer_count(wheel) >= initial_count  # Should have at least the new timer
        end
    end

    @testset "Time Overflow and Underflow" begin
        @testset "Negative Times" begin
            # Test with negative start time
            wheel = DeadlineTimerWheel(-1000, 1, 1024)

            # Schedule timer with negative deadline
            timer_id = schedule_timer!(wheel, -500)
            @test deadline(wheel, timer_id) == -500

            # Poll with negative current time
            expired_count = poll(wheel, -400, nothing) do client, now, timer_id
                return true
            end
            @test expired_count >= 0
        end

        @testset "Time Wrap-around" begin
            # Test near integer limits
            max_time = typemax(Int64) - 1000
            wheel = DeadlineTimerWheel(max_time, 1, 8)

            # Schedule timer near maximum value
            timer_id = schedule_timer!(wheel, max_time + 100)
            @test deadline(wheel, timer_id) == max_time + 100
        end
    end

    @testset "Invalid State Recovery" begin
        @testset "Corrupted Timer Count" begin
            wheel = DeadlineTimerWheel(1000, 8, 8)

            # Add some timers
            timer_ids = [schedule_timer!(wheel, 1000 + i*10) for i = 1:5]
            @test timer_count(wheel) == 5

            # Manually corrupt the timer count (simulating memory corruption)
            # Note: This is for testing robustness, not recommended in practice
            wheel.timer_count = 100

            # Operations should still work even with incorrect count
            for timer_id in timer_ids
                @test deadline(wheel, timer_id) != TimerWheels.NULL_DEADLINE
            end

            # Reset to correct state
            clear!(wheel)
            @test timer_count(wheel) == 0
        end
    end

    @testset "Resource Cleanup" begin
        @testset "Large Wheel Cleanup" begin
            # Create a large wheel with many timers
            wheel = DeadlineTimerWheel(0, 1, 1024)

            # Schedule many timers
            for i = 1:1000
                schedule_timer!(wheel, i)
            end
            @test timer_count(wheel) == 1000

            # Clear should handle large numbers efficiently
            clear!(wheel)
            @test timer_count(wheel) == 0

            # Wheel should be reusable after clear
            new_timer = schedule_timer!(wheel, 100)
            @test timer_count(wheel) == 1
            @test deadline(wheel, new_timer) == 100
        end
    end

    @testset "Iterator Edge Cases" begin
        @testset "Iterator During Modifications" begin
            wheel = DeadlineTimerWheel(1000, 8, 8)

            # Add some timers
            for i = 1:5
                schedule_timer!(wheel, 1000 + i*10)
            end

            # Start iteration
            iter_state = iterate(wheel)
            @test iter_state !== nothing

            # Modify wheel during iteration by clearing
            clear!(wheel)

            # Continue iteration - behavior is implementation-defined
            # but shouldn't crash
            remaining_items = []
            while iter_state !== nothing
                push!(remaining_items, iter_state[1])
                iter_state = iterate(wheel, iter_state[2])
            end

            # After clear, new iteration should be empty
            @test collect(wheel) == []
        end

        @testset "Empty Iterator Properties" begin
            wheel = DeadlineTimerWheel(1000, 8, 8)

            @test length(wheel) == 0
            @test isempty(collect(wheel))
            @test iterate(wheel) === nothing
            @test eltype(wheel) == Tuple{Int64,Int64}
        end
    end

    @testset "Parameter Validation Edge Cases" begin
        @testset "Power of 2 Boundary Cases" begin
            # Test edge cases for power of 2 validation
            @test_throws ArgumentError DeadlineTimerWheel(0, 1, 0)
            # Note: 1 is technically a power of 2 (2^0), so it's valid
            @test_nowarn DeadlineTimerWheel(0, 1, 1)
            @test_nowarn DeadlineTimerWheel(0, 1, 2)

            # Very large power of 2
            @test_nowarn DeadlineTimerWheel(0, 1, 2^20)
        end

        @testset "Resolution Edge Cases" begin
            # Test different resolution values
            @test_nowarn DeadlineTimerWheel(1000, 1, 8)  # 1 unit resolution
            @test_nowarn DeadlineTimerWheel(1000, 1024, 8)  # High resolution
            @test_nowarn DeadlineTimerWheel(1000, 2^20, 8)  # Very high resolution
        end
    end

end
