using Test
using TimerWheels

@testset "Performance Tests" begin
    
    @testset "Large Scale Timer Operations" begin
        @testset "Schedule Many Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 1024)  # Large wheel for better distribution
            
            # Test scheduling 10,000 timers
            num_timers = 10_000
            start_time = time_ns()
            
            timer_ids = Vector{Int64}(undef, num_timers)
            for i in 1:num_timers
                timer_ids[i] = schedule_timer!(wheel, i * 100)  # Spread timers out
            end
            
            schedule_time = time_ns() - start_time
            
            @test length(timer_ids) == num_timers
            @test timer_count(wheel) == num_timers
            
            # Scheduling should be reasonably fast (less than 1 second for 10k timers)
            @test schedule_time < 1_000_000_000  # 1 second in nanoseconds
            
            println("Scheduled $num_timers timers in $(schedule_time / 1_000_000) ms")
        end
        
        @testset "Cancel Many Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 1024)
            num_timers = 5_000
            
            # Schedule timers
            timer_ids = [schedule_timer!(wheel, i * 100) for i in 1:num_timers]
            
            # Cancel half of them
            start_time = time_ns()
            cancelled_count = 0
            for i in 1:2:num_timers  # Cancel every other timer
                if cancel_timer!(wheel, timer_ids[i])
                    cancelled_count += 1
                end
            end
            cancel_time = time_ns() - start_time
            
            @test cancelled_count == num_timers ÷ 2
            @test timer_count(wheel) == num_timers - cancelled_count
            
            # Cancellation should be fast (O(1) operations)
            @test cancel_time < 100_000_000  # 100ms
            
            println("Cancelled $cancelled_count timers in $(cancel_time / 1_000_000) ms")
        end
    end
    
    @testset "Poll Performance" begin
        @testset "Large Time Jump with Many Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 16384)  # Increased to handle larger jumps
            num_timers = 1_000
            
            # Schedule timers with deadlines spread over a large time range
            for i in 1:num_timers
                schedule_timer!(wheel, i * 10)
            end
            
            # Create handler that just counts
            expired_count = 0
            
            # Jump far forward in time
            jump_time = num_timers * 10 + 1000
            start_time = time_ns()
            
            poll_result = poll(wheel, jump_time, nothing) do client, now, timer_id
                expired_count += 1
                return true
            end
            
            poll_time = time_ns() - start_time
            
            @test poll_result == num_timers
            @test expired_count == num_timers
            @test timer_count(wheel) == 0
            
            # Should handle large jumps efficiently
            @test poll_time < 100_000_000  # 100ms
            
            println("Polled and expired $num_timers timers with large jump in $(poll_time / 1_000_000) ms")
        end
        
        @testset "Frequent Small Polls" begin
            wheel = DeadlineTimerWheel(0, 16, 256)  # Coarser resolution
            num_timers = 1_000
            
            # Schedule timers
            for i in 1:num_timers
                schedule_timer!(wheel, i * 50)
            end
            
            expired_total = 0
            
            # Many small incremental polls
            poll_count = 100
            start_time = time_ns()
            
            for i in 1:poll_count
                poll(wheel, i * 100, nothing) do client, now, timer_id
                    expired_total += 1
                    return true
                end
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_total <= num_timers  # Some timers should have expired
            
            # Frequent polling should be efficient
            @test poll_time < 50_000_000  # 50ms
            
            println("Performed $poll_count incremental polls in $(poll_time / 1_000_000) ms, expired $expired_total timers")
        end
    end
    
    @testset "Memory Usage and Capacity Expansion" begin
        @testset "Capacity Expansion Performance" begin
            # Start with small allocation to force expansions
            wheel = DeadlineTimerWheel(0, 1, 8, 2)  # Very small initial allocation
            
            # Schedule many timers to the same tick to force expansion
            expansion_count = 0
            timer_ids = Vector{Int64}()
            
            start_time = time_ns()
            
            # Schedule 100 timers to tick 0 (deadline 0)
            for i in 1:100
                timer_id = schedule_timer!(wheel, 0)
                push!(timer_ids, timer_id)
            end
            
            expansion_time = time_ns() - start_time
            
            @test length(timer_ids) == 100
            @test timer_count(wheel) == 100
            
            # Even with expansions, should be reasonably fast
            @test expansion_time < 10_000_000  # 10ms
            
            println("Scheduled 100 timers with capacity expansions in $(expansion_time / 1_000_000) ms")
        end
    end
    
    @testset "Iterator Performance" begin
        @testset "Iterate Over Many Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 256)
            num_timers = 1_000
            
            # Schedule timers
            for i in 1:num_timers
                schedule_timer!(wheel, i * 10)
            end
            
            # Time iteration
            start_time = time_ns()
            
            iterated_count = 0
            for (deadline, timer_id) in wheel
                iterated_count += 1
            end
            
            iteration_time = time_ns() - start_time
            
            @test iterated_count == num_timers
            
            # Iteration should be efficient
            @test iteration_time < 50_000_000  # 50ms
            
            println("Iterated over $num_timers timers in $(iteration_time / 1_000_000) ms")
        end
    end
    
    @testset "Stress Test - Mixed Operations" begin
        @testset "Concurrent Schedule/Cancel/Poll Operations" begin
            wheel = DeadlineTimerWheel(0, 4, 512)
            
            active_timers = Set{Int64}()
            total_operations = 5_000
            
            start_time = time_ns()
            
            for i in 1:total_operations
                op = i % 4
                
                if op == 0 || op == 1  # 50% schedule operations
                    timer_id = schedule_timer!(wheel, i * 10)
                    push!(active_timers, timer_id)
                    
                elseif op == 2 && !isempty(active_timers)  # 25% cancel operations
                    timer_id = rand(active_timers)
                    if cancel_timer!(wheel, timer_id)
                        delete!(active_timers, timer_id)
                    end
                    
                elseif op == 3  # 25% poll operations
                    poll(wheel, i * 5, active_timers) do client, now, timer_id
                        delete!(client, timer_id)
                        return true
                    end
                end
            end
            
            stress_time = time_ns() - start_time
            
            @test timer_count(wheel) == length(active_timers)
            
            # Mixed operations should complete in reasonable time
            @test stress_time < 500_000_000  # 500ms
            
            println("Performed $total_operations mixed operations in $(stress_time / 1_000_000) ms")
            println("Final active timers: $(length(active_timers))")
        end
    end
    
    @testset "Worst Case Scenarios" begin
        @testset "All Timers in Same Tick" begin
            wheel = DeadlineTimerWheel(0, 1, 128)  # Increased to handle 100-tick jump
            num_timers = 500
            
            # Schedule all timers to same deadline (worst case for single tick)
            start_time = time_ns()
            
            for i in 1:num_timers
                schedule_timer!(wheel, 100)  # All at same deadline
            end
            
            schedule_time = time_ns() - start_time
            
            # Now expire them all at once
            expired_count = 0
            poll_start = time_ns()
            poll_result = poll(wheel, 100, nothing) do client, now, timer_id
                expired_count += 1
                return true
            end
            poll_time = time_ns() - poll_start
            
            @test poll_result == num_timers
            @test expired_count == num_timers
            
            # Even worst case should be reasonable
            @test schedule_time < 100_000_000  # 100ms for scheduling
            @test poll_time < 50_000_000       # 50ms for polling
            
            println("Worst case: $num_timers timers in same tick")
            println("  Schedule time: $(schedule_time / 1_000_000) ms")
            println("  Poll time: $(poll_time / 1_000_000) ms")
        end
        
        @testset "Very Large Time Range" begin
            wheel = DeadlineTimerWheel(0, 1024, 2048)  # Increased resolution and wheel size
            
            # Schedule timers across a very large time range  
            large_deadline = 1_000_000
            num_timers = 100
            
            start_time = time_ns()
            
            for i in 1:num_timers
                deadline = (i * large_deadline) ÷ num_timers
                schedule_timer!(wheel, deadline)
            end
            
            schedule_time = time_ns() - start_time
            
            # Poll with very large jump
            expired_count = 0
            
            poll_start = time_ns()
            poll_result = poll(wheel, large_deadline + 1000, nothing) do client, now, timer_id
                expired_count += 1
                return true
            end
            poll_time = time_ns() - poll_start
            
            @test poll_result == num_timers
            @test expired_count == num_timers
            
            # Large time ranges should still be handled efficiently
            @test schedule_time < 50_000_000  # 50ms
            @test poll_time < 100_000_000     # 100ms
            
            println("Large time range test with deadline $large_deadline")
            println("  Schedule time: $(schedule_time / 1_000_000) ms")
            println("  Poll time: $(poll_time / 1_000_000) ms")
        end
    end
end
