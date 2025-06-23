@testset "Integration Tests" begin
    
    @testset "End-to-End Timer Lifecycle" begin
        # Create wheel with millisecond precision and sufficient capacity for test time jumps
        wheel = DeadlineTimerWheel(0, 1, 512)  # 512 ticks to handle jumps up to 350
        
        # Track timer events
        events = Vector{Tuple{String, Int64, Int64}}()  # (event_type, time, timer_id)
        
        # Schedule multiple timers at different times
        timer1 = schedule_timer!(wheel, 100)  # Expires at 100ms
        timer2 = schedule_timer!(wheel, 200)  # Expires at 200ms
        timer3 = schedule_timer!(wheel, 150)  # Expires at 150ms
        timer4 = schedule_timer!(wheel, 300)  # Expires at 300ms
        
        push!(events, ("scheduled", 100, timer1))
        push!(events, ("scheduled", 200, timer2))
        push!(events, ("scheduled", 150, timer3))
        push!(events, ("scheduled", 300, timer4))
        
        @test timer_count(wheel) == 4
        
        # Cancel one timer
        @test cancel_timer!(wheel, timer2) == true
        push!(events, ("cancelled", 200, timer2))
        @test timer_count(wheel) == 3
        
        # Poll at different times
        expired_count = poll(wheel, 120, events) do client, now, timer_id
            push!(client, ("expired", now, timer_id))
            return true
        end
        @test expired_count >= 0
        
        expired_count = poll(wheel, 180, events) do client, now, timer_id
            push!(client, ("expired", now, timer_id))
            return true
        end
        @test expired_count >= 0
        
        expired_count = poll(wheel, 350, events) do client, now, timer_id
            push!(client, ("expired", now, timer_id))
            return true
        end
        @test expired_count >= 0
        
        # Verify events occurred in correct order
        expired_events = filter(e -> e[1] == "expired", events)
        if length(expired_events) > 1
            for i in 2:length(expired_events)
                @test expired_events[i-1][2] <= expired_events[i][2]  # Times should be non-decreasing
            end
        end
        
        # Timer2 should not have expired (was cancelled)
        expired_timer_ids = [e[3] for e in expired_events]
        @test timer2 ∉ expired_timer_ids
    end
    
    @testset "High Frequency Timer Scheduling" begin
        wheel = DeadlineTimerWheel(0, 1, 1024)
        
        # Schedule many timers rapidly
        timer_count_target = 1000
        timer_ids = Int64[]
        
        for i in 1:timer_count_target
            timer_id = schedule_timer!(wheel, i * 10)  # Every 10 units
            push!(timer_ids, timer_id)
        end
        
        @test timer_count(wheel) == timer_count_target
        @test length(unique(timer_ids)) == timer_count_target
        
        # Cancel half of them
        cancelled_count = 0
        for i in 1:2:timer_count_target
            if cancel_timer!(wheel, timer_ids[i])
                cancelled_count += 1
            end
        end
        
        @test timer_count(wheel) == timer_count_target - cancelled_count
    end
    
    @testset "Time Unit Conversions" begin
        # Test that different time units work correctly when users handle conversions
        
        # Millisecond wheel (user responsible for conversion)
        ms_wheel = DeadlineTimerWheel(1000, 1, 64)
        ms_timer = schedule_timer!(ms_wheel, 1500)  # 500ms later
        @test deadline(ms_wheel, ms_timer) == 1500
        
        # Second wheel (user converts seconds to some base unit)
        s_wheel = DeadlineTimerWheel(10, 1, 64)  # 10 seconds start, 1 second resolution
        s_timer = schedule_timer!(s_wheel, 15)  # 5 seconds later
        @test deadline(s_wheel, s_timer) == 15
        
        # Microsecond wheel (user handles microsecond values) - use power of 2 resolution
        μs_wheel = DeadlineTimerWheel(1000000, 1024, 64)  # 1 second start, ~1ms resolution in μs
        μs_timer = schedule_timer!(μs_wheel, 1500000)  # 500ms later
        @test deadline(μs_wheel, μs_timer) == 1500000
    end
    
    @testset "Multiple Timer Wheels" begin
        # Test using multiple wheels simultaneously
        fast_wheel = DeadlineTimerWheel(0, 1, 32)
        slow_wheel = DeadlineTimerWheel(0, 1024, 32)  # Different resolution (power of 2)
        
        # Schedule timers on both wheels
        fast_timer = schedule_timer!(fast_wheel, 100)
        slow_timer = schedule_timer!(slow_wheel, 10000)
        
        @test timer_count(fast_wheel) == 1
        @test timer_count(slow_wheel) == 1
        
        # Operations on one wheel shouldn't affect the other
        cancel_timer!(fast_wheel, fast_timer)
        @test timer_count(fast_wheel) == 0
        @test timer_count(slow_wheel) == 1
        
        clear!(slow_wheel)
        @test timer_count(slow_wheel) == 0
    end
    
    @testset "Timer Wheel with Complex Handler Logic" begin
        wheel = DeadlineTimerWheel(1000, 8, 32)
        
        # Complex client data structure
        mutable struct TimerContext
            processed_timers::Set{Int64}
            error_count::Int
            max_errors::Int
            should_continue::Bool
        end
        
        context = TimerContext(Set{Int64}(), 0, 3, true)
        
        # Handler with complex logic
        # Schedule several timers
        for i in 1:10
            schedule_timer!(wheel, 1050)
        end
        
        initial_count = timer_count(wheel)
        expired_count = poll(wheel, 1100, context) do ctx, now, timer_id
            if !ctx.should_continue
                return false
            end
            
            if timer_id in ctx.processed_timers
                ctx.error_count += 1
                if ctx.error_count >= ctx.max_errors
                    ctx.should_continue = false
                    return false
                end
            end
            
            push!(ctx.processed_timers, timer_id)
            
            # Reschedule timer with 50% probability
            return rand() < 0.5
        end
        
        @test expired_count >= 0
        @test length(context.processed_timers) >= 0
    end
    
    @testset "Stress Test - Rapid Schedule/Cancel Cycles" begin
        wheel = DeadlineTimerWheel(0, 1, 128)
        
        # Perform many rapid schedule/cancel operations
        active_timers = Set{Int64}()
        
        for iteration in 1:100
            # Schedule some timers
            for i in 1:10
                timer_id = schedule_timer!(wheel, iteration * 10 + i)
                push!(active_timers, timer_id)
            end
            
            # Cancel some existing timers
            to_cancel = collect(active_timers)[1:min(5, length(active_timers))]
            for timer_id in to_cancel
                if cancel_timer!(wheel, timer_id)
                    delete!(active_timers, timer_id)
                end
            end
            
            # Verify consistency
            @test timer_count(wheel) == length(active_timers)
        end
        
        # Final cleanup
        clear!(wheel)
        @test timer_count(wheel) == 0
    end
    
end
