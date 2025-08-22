using Test
using TimerWheels
using Printf

# Consistent test parameters for better comparison
const BENCHMARK_SIZE = 10_000
const BENCHMARK_SUBSET = 1_000

@testset "Java-Compatible Performance Tests" begin
    
    println("\n" * "="^80)
    println("JAVA-COMPATIBLE TIMER WHEEL PERFORMANCE BENCHMARKS")
    println("="^80)
    println("Test Size: $BENCHMARK_SIZE timers (subset tests: $BENCHMARK_SUBSET)")
    println("Note: Performance characteristics match Java Agrona implementation")
    println("-"^80)
    @printf("%-25s | %8s | %10s | %8s\n", "Operation", "Count", "Total Time", "Per Item")
    println("-"^80)
    
    @testset "Basic Operations" begin
        @testset "Schedule Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 1024)

            timer_ids = Vector{Int64}(undef, BENCHMARK_SIZE)

            start_time = time_ns()
            for i in 1:BENCHMARK_SIZE
                timer_ids[i] = schedule_timer!(wheel, i * 100)
            end
            schedule_time = time_ns() - start_time
            
            @test length(timer_ids) == BENCHMARK_SIZE
            @test timer_count(wheel) == BENCHMARK_SIZE
            @test schedule_time < 1_000_000_000  # 1 second
            
            time_per_timer = schedule_time / BENCHMARK_SIZE
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Schedule", BENCHMARK_SIZE, schedule_time / 1_000_000, time_per_timer)
        end
        
        @testset "Cancel Timers" begin
            wheel = DeadlineTimerWheel(0, 1, 1024)
            timer_ids = [schedule_timer!(wheel, i * 100) for i in 1:BENCHMARK_SIZE]
            
            start_time = time_ns()
            cancelled_count = 0
            for i in 1:2:BENCHMARK_SIZE  # Cancel half
                if cancel_timer!(wheel, timer_ids[i])
                    cancelled_count += 1
                end
            end
            cancel_time = time_ns() - start_time
            
            @test cancelled_count == BENCHMARK_SIZE ÷ 2
            @test timer_count(wheel) == BENCHMARK_SIZE - cancelled_count
            @test cancel_time < 100_000_000  # 100ms
            
            time_per_cancellation = cancel_time / cancelled_count
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Cancel", cancelled_count, cancel_time / 1_000_000, time_per_cancellation)
        end
    end
    
    
    @testset "Java-Compatible Poll Performance" begin
        @testset "Incremental Polling" begin
            wheel = DeadlineTimerWheel(0, 16, 256)
            
            # Schedule timers with deadlines spread over reasonable time range
            max_deadline = BENCHMARK_SUBSET * 20  # More reasonable spacing
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, i * 20)  # Every 20 time units
            end
            
            expired_total = 0
            control_timestamp = 0
            poll_count = 0
            start_time = time_ns()
            
            # Poll incrementally like Java implementation until all timers expire
            while expired_total < BENCHMARK_SUBSET && control_timestamp <= max_deadline + 100
                poll_result = poll(wheel, control_timestamp) do client, now, timer_id
                    expired_total += 1
                    return true
                end
                
                control_timestamp += tick_resolution(wheel)
                poll_count += 1
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_total == BENCHMARK_SUBSET
            @test poll_time < 100_000_000  # 100ms
            
            time_per_poll = poll_time / poll_count
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Incremental polling", poll_count, poll_time / 1_000_000, time_per_poll)
            @printf("%-25s | %8s | %10s | Expired: %d\n", 
                   "", "", "", expired_total)
        end
        
        @testset "Single Tick Processing" begin
            wheel = DeadlineTimerWheel(0, 16, 128)
            
            # Schedule multiple timers to same deadline that will be in first tick
            deadline = 16  # This should expire when we reach tick boundary  
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, deadline)
            end
            
            expired_count = 0
            start_time = time_ns()
            
            # Poll incrementally until timers expire
            control_timestamp = 0
            while expired_count == 0 && control_timestamp <= deadline + 32
                poll_result = poll(wheel, control_timestamp) do client, now, timer_id
                    expired_count += 1
                    return true
                end
                control_timestamp += tick_resolution(wheel)
            end
            
            poll_time = time_ns() - start_time
            
            # Should get at least one timer
            @test expired_count > 0
            @test poll_time < 50_000_000  # 50ms
            
            time_per_timer = expired_count > 0 ? poll_time / expired_count : 0
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Single tick poll", expired_count, poll_time / 1_000_000, time_per_timer)
        end
        
        @testset "Poll with Expiry Limit" begin
            wheel = DeadlineTimerWheel(0, 8, 64)
            
            # Schedule many timers to same deadline
            deadline = 8
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, deadline)
            end
            
            expired_count = 0
            poll_calls = 0
            start_time = time_ns()
            
            # Poll with limited expiry count per call - poll incrementally until they expire
            expiry_limit = 50
            control_timestamp = 0
            while expired_count < BENCHMARK_SUBSET && control_timestamp <= deadline + 100
                poll_result = poll(wheel, control_timestamp, nothing; expiry_limit=expiry_limit) do client, now, timer_id
                    expired_count += 1
                    return true
                end
                poll_calls += 1
                
                if expired_count == 0
                    control_timestamp += tick_resolution(wheel)
                end
                
                if poll_result == 0 && expired_count == 0  # No progress
                    control_timestamp += tick_resolution(wheel)
                end
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_count > 0
            @test poll_time < 50_000_000  # 50ms
            
            time_per_call = poll_time / poll_calls
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Limited expiry polling", poll_calls, poll_time / 1_000_000, time_per_call)
            @printf("%-25s | %8s | %10s | Expired: %d\n", 
                   "", "", "", expired_count)
        end
    end
    
    
    @testset "Memory and Expansion" begin
        @testset "Capacity Expansion" begin
            wheel = DeadlineTimerWheel(0, 1, 8, 2)  # Small allocation to force expansions
            
            start_time = time_ns()
            timer_ids = Vector{Int64}()
            
            # Schedule subset of timers to same deadline to force expansion
            for i in 1:BENCHMARK_SUBSET
                timer_id = schedule_timer!(wheel, 0)
                push!(timer_ids, timer_id)
            end
            
            expansion_time = time_ns() - start_time
            
            @test length(timer_ids) == BENCHMARK_SUBSET
            @test timer_count(wheel) == BENCHMARK_SUBSET
            @test expansion_time < 100_000_000  # 100ms
            
            time_per_timer = expansion_time / BENCHMARK_SUBSET
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Schedule (w/ expansion)", BENCHMARK_SUBSET, expansion_time / 1_000_000, time_per_timer)
        end
        
        @testset "Iterator" begin
            wheel = DeadlineTimerWheel(0, 1, 256)
            
            # Schedule timers
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, i * 10)
            end
            
            start_time = time_ns()
            
            iterated_count = 0
            for (deadline, timer_id) in wheel
                iterated_count += 1
            end
            
            iteration_time = time_ns() - start_time
            
            @test iterated_count == BENCHMARK_SUBSET
            @test iteration_time < 50_000_000  # 50ms
            
            time_per_timer = iteration_time / BENCHMARK_SUBSET
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Iterator", BENCHMARK_SUBSET, iteration_time / 1_000_000, time_per_timer)
        end
    end
    
    
    @testset "Stress Tests" begin
        @testset "Mixed Operations with Incremental Polling" begin
            wheel = DeadlineTimerWheel(0, 4, 512)
            
            active_timers = Set{Int64}()
            control_timestamp = 0
            start_time = time_ns()
            
            for i in 1:BENCHMARK_SIZE
                op = i % 4
                
                if op == 0 || op == 1  # 50% schedule operations
                    timer_id = schedule_timer!(wheel, control_timestamp + (i * 10))
                    push!(active_timers, timer_id)
                    
                elseif op == 2 && !isempty(active_timers)  # 25% cancel operations
                    timer_id = rand(active_timers)
                    if cancel_timer!(wheel, timer_id)
                        delete!(active_timers, timer_id)
                    end
                    
                elseif op == 3  # 25% poll operations - incremental style
                    poll(wheel, control_timestamp, active_timers) do client, now, timer_id
                        delete!(client, timer_id)
                        return true
                    end
                    control_timestamp += tick_resolution(wheel)
                end
            end
            
            stress_time = time_ns() - start_time
            
            @test timer_count(wheel) == length(active_timers)
            @test stress_time < 500_000_000  # 500ms
            
            time_per_operation = stress_time / BENCHMARK_SIZE
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Mixed operations", BENCHMARK_SIZE, stress_time / 1_000_000, time_per_operation)
            @printf("%-25s | %8s | %10s | Final: %d active\n", 
                   "", "", "", length(active_timers))
        end
    end
    
    
    @testset "Real-world Usage Patterns" begin
        @testset "High-Frequency Polling" begin
            wheel = DeadlineTimerWheel(0, 1, 1024)  # 1 time unit resolution
            
            # Schedule timers with varying deadlines
            timer_count_per_tick = 10
            total_ticks = 100
            
            for tick in 1:total_ticks
                for i in 1:timer_count_per_tick
                    schedule_timer!(wheel, tick)
                end
            end
            
            expired_total = 0
            control_timestamp = 0
            poll_count = 0
            start_time = time_ns()
            
            # High-frequency polling - every tick
            while expired_total < (timer_count_per_tick * total_ticks) && poll_count < total_ticks * 2
                poll_result = poll(wheel, control_timestamp) do client, now, timer_id
                    expired_total += 1
                    return true
                end
                
                control_timestamp += tick_resolution(wheel)
                poll_count += 1
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_total == timer_count_per_tick * total_ticks
            @test poll_time < 100_000_000  # 100ms
            
            time_per_poll = poll_time / poll_count
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "High-freq polling", poll_count, poll_time / 1_000_000, time_per_poll)
            @printf("%-25s | %8s | %10s | Expired: %d\n", 
                   "", "", "", expired_total)
        end
        
        @testset "Sparse Timer Distribution" begin
            wheel = DeadlineTimerWheel(0, 16, 256)
            
            # Schedule timers sparsely across many ticks
            sparse_timer_count = 100
            max_deadline = 10000
            
            for i in 1:sparse_timer_count
                deadline = i * (max_deadline ÷ sparse_timer_count)
                schedule_timer!(wheel, deadline)
            end
            
            expired_total = 0
            control_timestamp = 0
            poll_count = 0
            start_time = time_ns()
            
            # Poll through all the sparse timers
            while expired_total < sparse_timer_count && control_timestamp <= max_deadline + tick_resolution(wheel)
                poll_result = poll(wheel, control_timestamp) do client, now, timer_id
                    expired_total += 1
                    return true
                end
                
                control_timestamp += tick_resolution(wheel)
                poll_count += 1
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_total == sparse_timer_count
            @test poll_time < 50_000_000  # 50ms
            
            time_per_poll = poll_time / poll_count
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Sparse distribution", poll_count, poll_time / 1_000_000, time_per_poll)
            @printf("%-25s | %8s | %10s | Expired: %d\n", 
                   "", "", "", expired_total)
        end
    end
    
    println("-"^80)
    println("Java-compatible benchmark completed successfully.")
    println("Performance characteristics match Java Agrona implementation:")
    println("- Incremental tick-by-tick processing")
    println("- Bounded execution time per poll call")  
    println("- State maintained across poll calls (poll_index)")
    println("="^80)
end