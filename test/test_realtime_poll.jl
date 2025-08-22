@testset "Real-Time Poll Index Tests" begin

    @testset "Expiry Limit Respect with poll_index" begin
        # Create a wheel with current time
        start_time = Int64(1000)
        wheel = DeadlineTimerWheel(start_time, 1024, 64)  # 2^10 resolution, 64 ticks

        # Schedule 50 timers that will all expire at the same time
        num_timers = 50
        expire_time = start_time + 2048  # 2 ticks later

        scheduled_ids = Int64[]
        for i = 1:num_timers
            timer_id = schedule_timer!(wheel, expire_time)
            push!(scheduled_ids, timer_id)
        end

        @test timer_count(wheel) == num_timers

        # Create handler that tracks expired timers
        expired_timers = Int64[]

        # Poll with strict expiry limit
        poll_time = expire_time + 1000  # Poll after all should expire
        expiry_limit = 10
        total_expired = 0
        poll_calls = 0

        # Keep polling until all timers are processed
        while timer_count(wheel) > 0 && poll_calls < 20  # Safety limit
            poll_calls += 1
            expired_count = poll(
                wheel,
                poll_time,
                expired_timers;
                expiry_limit = expiry_limit,
            ) do client, now, timer_id
                push!(client, timer_id)
                return true
            end
            total_expired += expired_count

            # Should never exceed expiry limit
            @test expired_count <= expiry_limit

            # If we hit the limit, there should be more timers to process
            if expired_count == expiry_limit && timer_count(wheel) > 0
                @test timer_count(wheel) > 0  # More work to do
            end
        end

        # Verify all timers were processed
        @test total_expired == num_timers
        @test timer_count(wheel) == 0
        @test length(expired_timers) == num_timers

        # Verify no timer was processed twice
        @test length(unique(expired_timers)) == num_timers

        # Verify all scheduled timers were expired
        for timer_id in scheduled_ids
            @test timer_id in expired_timers
        end

        println(
            "Processed $num_timers timers in $poll_calls poll calls (limit: $expiry_limit)",
        )
    end

    @testset "poll_index State Preservation" begin
        start_time = Int64(2000)
        wheel = DeadlineTimerWheel(start_time, 512, 32)  # 2^9 resolution, 32 ticks

        # Schedule timers in the same tick (tick 2)
        expire_time = start_time + 1536  # 3 * 512 = tick 3
        num_timers = 20

        for i = 1:num_timers
            schedule_timer!(wheel, expire_time)
        end

        # Handler that tracks processing order
        processing_order = Int64[]

        # Poll with very small expiry limit to force multiple calls
        poll_time = expire_time + 100
        expiry_limit = 3

        # First poll - should process exactly 3 timers
        expired1 = poll(
            wheel,
            poll_time,
            processing_order;
            expiry_limit = expiry_limit,
        ) do client, now, timer_id
            push!(client, timer_id)
            return true
        end
        @test expired1 == 3
        @test timer_count(wheel) == num_timers - 3

        # Second poll - should continue from where we left off
        expired2 = poll(
            wheel,
            poll_time,
            processing_order;
            expiry_limit = expiry_limit,
        ) do client, now, timer_id
            push!(client, timer_id)
            return true
        end
        @test expired2 == 3
        @test timer_count(wheel) == num_timers - 6

        # Verify no overlap in timer IDs processed
        first_batch = processing_order[1:3]
        second_batch = processing_order[4:6]
        @test isempty(intersect(first_batch, second_batch))

        # Continue until all are processed
        total_polls = 2
        while timer_count(wheel) > 0 && total_polls < 10
            total_polls += 1
            expired = poll(
                wheel,
                poll_time,
                processing_order;
                expiry_limit = expiry_limit,
            ) do client, now, timer_id
                push!(client, timer_id)
                return true
            end
            @test expired <= expiry_limit
        end

        @test timer_count(wheel) == 0
        @test length(processing_order) == num_timers
        @test length(unique(processing_order)) == num_timers
    end

    @testset "Handler Rejection with poll_index" begin
        start_time = Int64(3000)
        wheel = DeadlineTimerWheel(start_time, 256, 16)

        # Schedule several timers
        expire_time = start_time + 512
        for i = 1:10
            schedule_timer!(wheel, expire_time)
        end

        # Poll with expiry limit
        poll_time = expire_time + 100
        initial_count = timer_count(wheel)
        expired = poll(wheel, poll_time, nothing; expiry_limit = 5) do client, now, timer_id
            if (timer_id % 3) == 0
                return false  # Reject this timer
            end
            return true  # Accept this timer
        end

        # Should have processed some timers but not necessarily all
        @test expired >= 0
        @test timer_count(wheel) < initial_count  # Some timers were processed

        # Remaining timers should include the rejected ones
        remaining = timer_count(wheel)
        @test remaining > 0  # Some timers should remain (rejected ones)
    end

    @testset "Empty Wheel with Expiry Limit" begin
        start_time = Int64(4000)
        wheel = DeadlineTimerWheel(start_time, 128, 8)

        @test timer_count(wheel) == 0

        # Poll empty wheel with various expiry limits
        for limit in [1, 10, 100]
            expired = poll(
                wheel,
                start_time + 1000,
                nothing;
                expiry_limit = limit,
            ) do client, now, timer_id
                return true
            end
            @test expired == 0
            @test timer_count(wheel) == 0
        end
    end

    @testset "Time Advancement with poll_index" begin
        start_time = Int64(5000)
        wheel = DeadlineTimerWheel(start_time, 1024, 64)

        # Initial state
        @test wheel.current_tick == 0
        @test wheel.poll_index == 0

        # Schedule a timer for later
        timer_id = schedule_timer!(wheel, start_time + 10240)  # 10 ticks later

        # Poll at an intermediate time with expiry limit
        intermediate_time = start_time + 5120  # 5 ticks later
        expired = poll(
            wheel,
            intermediate_time,
            nothing;
            expiry_limit = 5,
        ) do client, now, timer_id
            return true
        end

        # Time should advance even with expiry limit
        @test wheel.current_tick >= 5
        @test expired == 0  # Timer shouldn't expire yet
        @test timer_count(wheel) == 1  # Timer still there

        # Poll at expiry time
        expiry_time = start_time + 11264  # Past the timer deadline
        expired =
            poll(wheel, expiry_time, nothing; expiry_limit = 5) do client, now, timer_id
                return true
            end

        @test expired == 1
        @test timer_count(wheel) == 0
    end
end
