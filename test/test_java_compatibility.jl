"""
Test suite based on Java Agrona DeadlineTimerWheelTest to ensure compatibility
with the Java poll algorithm implementation.
"""

using Test
using TimerWheels

@testset "Java Agrona Compatibility Tests" begin
    RESOLUTION = 1048576  # Power of 2, similar to Java RESOLUTION
    
    @testset "Basic Configuration" begin
        @test_throws ArgumentError DeadlineTimerWheel(0, RESOLUTION, 10)  # Non-power of 2 ticks
        @test_throws ArgumentError DeadlineTimerWheel(0, 17, 8)  # Non-power of 2 resolution
        
        # Default configuration test
        start_time = 7
        tick_resolution = 16
        ticks_per_wheel = 8
        wheel = DeadlineTimerWheel(start_time, tick_resolution, ticks_per_wheel)
        
        @test TimerWheels.tick_resolution(wheel) == tick_resolution
        @test TimerWheels.ticks_per_wheel(wheel) == ticks_per_wheel
        @test TimerWheels.start_time(wheel) == start_time
    end
    
    @testset "Timer on Edge of Tick" begin
        control_timestamp = 0
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 1024)
        
        deadline = 5 * TimerWheels.tick_resolution(wheel)
        timer_id = schedule_timer!(wheel, deadline)
        @test TimerWheels.deadline(wheel, timer_id) == deadline
        
        while fired_timestamp == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        # Timer should fire at the first tick after the deadline
        @test fired_timestamp == 6 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Non-Zero Start Time" begin
        control_timestamp = 100 * RESOLUTION
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 1024)
        
        timer_id = schedule_timer!(wheel, control_timestamp + (5 * TimerWheels.tick_resolution(wheel)))
        
        while fired_timestamp == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp == 106 * RESOLUTION
    end
    
    @testset "Nano Time Unit Timers" begin
        control_timestamp = 0
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 1024)
        
        timer_id = schedule_timer!(wheel, control_timestamp + (5 * TimerWheels.tick_resolution(wheel)) + 1)
        
        while fired_timestamp == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp == 6 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Multiple Rounds" begin
        control_timestamp = 0
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 16)
        
        timer_id = schedule_timer!(wheel, control_timestamp + (63 * TimerWheels.tick_resolution(wheel)))
        
        while fired_timestamp == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp == 64 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Timer Cancellation" begin
        control_timestamp = 0
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 256)
        
        timer_id = schedule_timer!(wheel, control_timestamp + (63 * TimerWheels.tick_resolution(wheel)))
        
        # Poll for a while without the timer firing
        while fired_timestamp == -1 && control_timestamp < (16 * TimerWheels.tick_resolution(wheel))
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test cancel_timer!(wheel, timer_id) == true
        @test cancel_timer!(wheel, timer_id) == false  # Second cancel should fail
        
        # Continue polling - timer should not fire
        while fired_timestamp == -1 && control_timestamp < (128 * TimerWheels.tick_resolution(wheel))
            poll(wheel, control_timestamp) do clientd, now, tid
                fired_timestamp = now
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp == -1  # Timer should not have fired
    end
    
    @testset "Expiring Timers in Previous Ticks" begin
        control_timestamp = 0
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 256)
        
        timer_id = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        
        poll_start_time = 32 * TimerWheels.tick_resolution(wheel)
        control_timestamp += poll_start_time
        
        while fired_timestamp == -1 && control_timestamp < (128 * TimerWheels.tick_resolution(wheel))
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            
            if current_tick_time(wheel) > poll_start_time
                control_timestamp += TimerWheels.tick_resolution(wheel)
            end
        end
        
        @test fired_timestamp == poll_start_time
    end
    
    @testset "Multiple Timers Different Ticks" begin
        control_timestamp = 0
        fired_timestamp1 = -1
        fired_timestamp2 = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 256)
        
        timer_id1 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        timer_id2 = schedule_timer!(wheel, control_timestamp + (23 * TimerWheels.tick_resolution(wheel)))
        
        while fired_timestamp1 == -1 || fired_timestamp2 == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id1
                    fired_timestamp1 = now
                elseif tid == timer_id2
                    fired_timestamp2 = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp1 == 16 * TimerWheels.tick_resolution(wheel)
        @test fired_timestamp2 == 24 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Multiple Timers Same Tick Same Round" begin
        control_timestamp = 0
        fired_timestamp1 = -1
        fired_timestamp2 = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        
        timer_id1 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        timer_id2 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        
        while fired_timestamp1 == -1 || fired_timestamp2 == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id1
                    fired_timestamp1 = now
                elseif tid == timer_id2
                    fired_timestamp2 = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp1 == 16 * TimerWheels.tick_resolution(wheel)
        @test fired_timestamp2 == 16 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Multiple Timers Same Tick Different Round" begin
        control_timestamp = 0
        fired_timestamp1 = -1
        fired_timestamp2 = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        
        timer_id1 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        timer_id2 = schedule_timer!(wheel, control_timestamp + (23 * TimerWheels.tick_resolution(wheel)))
        
        while fired_timestamp1 == -1 || fired_timestamp2 == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id1
                    fired_timestamp1 = now
                elseif tid == timer_id2
                    fired_timestamp2 = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp1 == 16 * TimerWheels.tick_resolution(wheel)
        @test fired_timestamp2 == 24 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "Expiry Limit" begin
        control_timestamp = 0
        fired_timestamp1 = -1
        fired_timestamp2 = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        
        timer_id1 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        timer_id2 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        
        num_expired = 0
        
        while fired_timestamp1 == -1
            expired = poll(wheel, control_timestamp; expiry_limit=1) do clientd, now, tid
                @test tid == timer_id1  # First timer should fire first
                fired_timestamp1 = now
                return true
            end
            num_expired += expired
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test num_expired == 1
        
        while fired_timestamp2 == -1
            expired = poll(wheel, control_timestamp; expiry_limit=1) do clientd, now, tid
                @test tid == timer_id2  # Second timer should fire next
                fired_timestamp2 = now
                return true
            end
            num_expired += expired
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test num_expired == 2
        @test fired_timestamp1 == 16 * TimerWheels.tick_resolution(wheel)
        @test fired_timestamp2 == 17 * TimerWheels.tick_resolution(wheel)
    end
    
    @testset "False Return from Handler" begin
        control_timestamp = 0
        fired_timestamp1 = -1
        fired_timestamp2 = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        
        timer_id1 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        timer_id2 = schedule_timer!(wheel, control_timestamp + (15 * TimerWheels.tick_resolution(wheel)))
        
        num_expired = 0
        
        while fired_timestamp1 == -1 || fired_timestamp2 == -1
            expired = poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id1
                    if fired_timestamp1 == -1
                        fired_timestamp1 = now
                        return false  # Reject first time
                    end
                    fired_timestamp1 = now
                elseif tid == timer_id2
                    fired_timestamp2 = now
                end
                return true
            end
            num_expired += expired
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp1 == 17 * TimerWheels.tick_resolution(wheel)
        @test fired_timestamp2 == 17 * TimerWheels.tick_resolution(wheel)
        @test num_expired == 2
    end
    
    @testset "Timer Iteration" begin
        control_timestamp = 0
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        deadline1 = control_timestamp + (15 * TimerWheels.tick_resolution(wheel))
        deadline2 = control_timestamp + ((15 + 7) * TimerWheels.tick_resolution(wheel))
        
        timer_id1 = schedule_timer!(wheel, deadline1)
        timer_id2 = schedule_timer!(wheel, deadline2)
        
        timer_map = Dict{Int64, Int64}()
        for (deadline, timer_id) in wheel
            timer_map[deadline] = timer_id
        end
        
        @test length(timer_map) == 2
        @test timer_map[deadline1] == timer_id1
        @test timer_map[deadline2] == timer_id2
    end
    
    @testset "Clear Scheduled Timers" begin
        control_timestamp = 0
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        deadline1 = control_timestamp + (15 * TimerWheels.tick_resolution(wheel))
        deadline2 = control_timestamp + ((15 + 7) * TimerWheels.tick_resolution(wheel))
        
        timer_id1 = schedule_timer!(wheel, deadline1)
        timer_id2 = schedule_timer!(wheel, deadline2)
        
        clear!(wheel)
        
        @test timer_count(wheel) == 0
        @test TimerWheels.deadline(wheel, timer_id1) == TimerWheels.NULL_DEADLINE
        @test TimerWheels.deadline(wheel, timer_id2) == TimerWheels.NULL_DEADLINE
    end
    
    @testset "Reset Start Time with Active Timers" begin
        control_timestamp = 0
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 8)
        
        schedule_timer!(wheel, control_timestamp + 100)
        @test_throws ArgumentError reset_start_time!(wheel, control_timestamp + 1)
    end
    
    @testset "Advance Wheel to Later Time" begin
        start_time = 0
        wheel = DeadlineTimerWheel(start_time, RESOLUTION, 8)
        
        schedule_timer!(wheel, start_time + 100000)
        
        original_time = current_tick_time(wheel)
        current_tick_time!(wheel, original_time * 5)
        
        @test current_tick_time(wheel) == original_time * 6
    end
    
    @testset "Schedule Deadline in Past" begin
        control_timestamp = 100 * RESOLUTION
        fired_timestamp = -1
        wheel = DeadlineTimerWheel(control_timestamp, RESOLUTION, 1024)
        
        deadline = control_timestamp - 3
        timer_id = schedule_timer!(wheel, deadline)
        
        while fired_timestamp == -1
            poll(wheel, control_timestamp) do clientd, now, tid
                if tid == timer_id
                    fired_timestamp = now
                end
                return true
            end
            control_timestamp += TimerWheels.tick_resolution(wheel)
        end
        
        @test fired_timestamp > deadline
    end
    
    @testset "Expand Tick Allocation" begin
        tick_allocation = 4
        ticks_per_wheel = 8
        wheel = DeadlineTimerWheel(0, RESOLUTION, ticks_per_wheel, tick_allocation)
        
        timer_count_val = tick_allocation + 1
        timer_ids = Vector{Int64}(undef, timer_count_val)
        
        for i in 1:timer_count_val
            timer_ids[i] = schedule_timer!(wheel, i)
        end
        
        for i in 1:timer_count_val
            @test TimerWheels.deadline(wheel, timer_ids[i]) == i
        end
        
        deadline_by_timer_id = Dict{Int64, Int64}()
        expired_count = poll(wheel, timer_count_val + 1) do clientd, now, timer_id
            deadline_by_timer_id[timer_id] = now
            return true
        end
        
        @test expired_count == timer_count_val
        @test length(deadline_by_timer_id) == timer_count_val
    end
end