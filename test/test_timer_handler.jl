@testset "Poll Callback Tests" begin

    @testset "Basic Callback Functionality" begin
        wheel = DeadlineTimerWheel(1000, 1024, 64)

        # Schedule a timer
        timer_id = schedule_timer!(wheel, 2048)
        @test timer_count(wheel) == 1

        # Test with simple callback
        expired_timers = Int64[]
        count = poll(wheel, 2048 + 500, expired_timers) do client, now, timer_id
            push!(client, timer_id)
            return true
        end

        @test count == 1
        @test timer_count(wheel) == 0
        @test length(expired_timers) == 1
        @test expired_timers[1] == timer_id
    end

    @testset "Callback with Different Client Types" begin
        wheel = DeadlineTimerWheel(2000, 512, 32)

        # Test with Int client data
        timer_id = schedule_timer!(wheel, 3000)
        result = poll(wheel, 3500, 42) do client, now, timer_id
            return client > 0
        end
        @test result == 1
        @test timer_count(wheel) == 0

        # Test with custom struct
        struct TestClient
            value::String
            results::Vector{Int64}
        end

        wheel2 = DeadlineTimerWheel(3000, 256, 16)
        timer_id2 = schedule_timer!(wheel2, 4000)

        test_client = TestClient("test", Int64[])
        result2 = poll(wheel2, 4500, test_client) do client, now, timer_id
            push!(client.results, timer_id)
            return client.value == "test"
        end

        @test result2 == 1
        @test timer_count(wheel2) == 0
        @test length(test_client.results) == 1
        @test test_client.results[1] == timer_id2
    end

    @testset "Callback Return Values" begin
        wheel = DeadlineTimerWheel(4000, 128, 32)  # 32 ticks for larger safe jump

        # Schedule multiple timers
        timer1 = schedule_timer!(wheel, 5000)
        timer2 = schedule_timer!(wheel, 5000)
        timer3 = schedule_timer!(wheel, 5000)
        @test timer_count(wheel) == 3

        # Callback that always returns true (continue processing)
        count1 = poll(wheel, 5500, nothing) do client, now, timer_id
            return true
        end
        @test count1 == 3
        @test timer_count(wheel) == 0

        # Reset and test callback that returns false (reject timer and stop processing)
        clear!(wheel)
        timer4 = schedule_timer!(wheel, 5000)
        timer5 = schedule_timer!(wheel, 5000)
        timer6 = schedule_timer!(wheel, 5000)
        @test timer_count(wheel) == 3

        processed = Int64[]
        count2 = poll(wheel, 5500, processed) do client, now, timer_id
            push!(client, timer_id)
            return length(client) < 2  # Accept first timer, reject second
        end

        @test count2 == 1  # Only 1 timer was successfully processed (2nd was rejected)
        @test timer_count(wheel) == 2  # 2 timers remain (1 rejected, 1 not reached)
        @test length(processed) == 2  # Both timers were attempted (1 accepted, 1 rejected)

        # Callback with conditional logic
        clear!(wheel)
        for i = 1:4
            schedule_timer!(wheel, 5000)
        end

        even_timers = Int64[]
        count3 = poll(wheel, 5500, even_timers) do client, now, timer_id
            if timer_id % 2 == 0
                push!(client, timer_id)
                return true
            else
                return false  # Reject odd timer IDs
            end
        end

        # Should process until hitting first odd timer, then stop
        @test count3 >= 0
        @test timer_count(wheel) > 0  # Some timers should remain
    end

end
