using Test
using TimerWheels
using Printf

# Consistent test parameters for better comparison
const BENCHMARK_SIZE = 10_000
const BENCHMARK_SUBSET = 1_000

@testset "Performance Tests" begin
    
    println("\n" * "="^80)
    println("TIMER WHEEL PERFORMANCE BENCHMARKS")
    println("="^80)
    println("Test Size: $BENCHMARK_SIZE timers (subset tests: $BENCHMARK_SUBSET)")
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
    
    
    @testset "Poll Performance" begin
        @testset "Large Time Jump Poll" begin
            wheel = DeadlineTimerWheel(0, 1, 16384)
            
            # Schedule subset of timers with deadlines spread over time range
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, i * 10)
            end
            
            expired_count = 0
            jump_time = BENCHMARK_SUBSET * 10 + 1000
            start_time = time_ns()
            
            poll_result = poll(wheel, jump_time, nothing) do client, now, timer_id
                expired_count += 1
                return true
            end
            
            poll_time = time_ns() - start_time
            
            @test poll_result == BENCHMARK_SUBSET
            @test expired_count == BENCHMARK_SUBSET
            @test timer_count(wheel) == 0
            @test poll_time < 100_000_000  # 100ms
            
            time_per_timer = poll_time / BENCHMARK_SUBSET
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Poll (large jump)", BENCHMARK_SUBSET, poll_time / 1_000_000, time_per_timer)
        end
        
        @testset "Incremental Polls" begin
            wheel = DeadlineTimerWheel(0, 16, 256)
            
            # Schedule timers
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, i * 50)
            end
            
            expired_total = 0
            poll_count = 100
            start_time = time_ns()
            
            for i in 1:poll_count
                poll(wheel, i * 100, nothing) do client, now, timer_id
                    expired_total += 1
                    return true
                end
            end
            
            poll_time = time_ns() - start_time
            
            @test expired_total <= BENCHMARK_SUBSET
            @test poll_time < 50_000_000  # 50ms
            
            time_per_poll = poll_time / poll_count
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Poll (incremental)", poll_count, poll_time / 1_000_000, time_per_poll)
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
        @testset "Mixed Operations" begin
            wheel = DeadlineTimerWheel(0, 4, 512)
            
            active_timers = Set{Int64}()
            start_time = time_ns()
            
            for i in 1:BENCHMARK_SIZE
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
            @test stress_time < 500_000_000  # 500ms
            
            time_per_operation = stress_time / BENCHMARK_SIZE
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Mixed operations", BENCHMARK_SIZE, stress_time / 1_000_000, time_per_operation)
            @printf("%-25s | %8s | %10s | Final: %d active\n", 
                   "", "", "", length(active_timers))
        end
    end
    
    
    @testset "Worst Case Scenarios" begin
        @testset "Same Tick Clustering" begin
            wheel = DeadlineTimerWheel(0, 1, 128)
            
            # Schedule all timers to same deadline (worst case)
            start_time = time_ns()
            
            for i in 1:BENCHMARK_SUBSET
                schedule_timer!(wheel, 100)
            end
            
            schedule_time = time_ns() - start_time
            
            # Expire them all at once
            expired_count = 0
            poll_start = time_ns()
            poll_result = poll(wheel, 100, nothing) do client, now, timer_id
                expired_count += 1
                return true
            end
            poll_time = time_ns() - poll_start
            
            @test poll_result == BENCHMARK_SUBSET
            @test expired_count == BENCHMARK_SUBSET
            @test schedule_time < 100_000_000  # 100ms
            @test poll_time < 50_000_000       # 50ms
            
            schedule_per_timer = schedule_time / BENCHMARK_SUBSET
            poll_per_timer = poll_time / BENCHMARK_SUBSET
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Schedule (same tick)", BENCHMARK_SUBSET, schedule_time / 1_000_000, schedule_per_timer)
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Poll (same tick)", BENCHMARK_SUBSET, poll_time / 1_000_000, poll_per_timer)
        end
        
        @testset "Large Time Range" begin
            wheel = DeadlineTimerWheel(0, 1024, 2048)
            
            # Schedule timers across very large time range  
            large_deadline = 1_000_000
            
            start_time = time_ns()
            
            for i in 1:BENCHMARK_SUBSET
                deadline = (i * large_deadline) ÷ BENCHMARK_SUBSET
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
            
            @test poll_result == BENCHMARK_SUBSET
            @test expired_count == BENCHMARK_SUBSET
            @test schedule_time < 50_000_000   # 50ms
            @test poll_time < 100_000_000      # 100ms
            
            schedule_per_timer = schedule_time / BENCHMARK_SUBSET
            poll_per_timer = poll_time / BENCHMARK_SUBSET
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Schedule (large range)", BENCHMARK_SUBSET, schedule_time / 1_000_000, schedule_per_timer)
            @printf("%-25s | %8d | %10.3f ms | %8.1f ns\n", 
                   "Poll (large range)", BENCHMARK_SUBSET, poll_time / 1_000_000, poll_per_timer)
        end
    end
    
    println("-"^80)
    println("Benchmark completed. All operations within acceptable performance bounds.")
    println("="^80)
end
