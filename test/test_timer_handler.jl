@testset "TimerHandler Tests" begin
    
    @testset "TimerHandler Construction" begin
        # Test basic construction
        client_data = "test_data"
        handler = TimerHandler(client_data) do client, now, timer_id
            return true
        end
        
        @test handler isa TimerHandler{String}
        @test handler.clientd == client_data
        @test handler.on_expiry isa TimerWheels.OnExpiryWrapper{String}
    end
    
    @testset "TimerHandler with Different Client Types" begin
        # Test with Int client data
        int_handler = TimerHandler(42) do client, now, timer_id
            return client > 0
        end
        @test int_handler isa TimerHandler{Int}
        @test int_handler.clientd == 42
        
        # Test with custom struct
        struct TestClient
            value::String
        end
        
        test_client = TestClient("test")
        struct_handler = TimerHandler(test_client) do client, now, timer_id
            return client.value == "test"
        end
        @test struct_handler isa TimerHandler{TestClient}
        @test struct_handler.clientd.value == "test"
    end
    
    @testset "TimerHandler Callback Execution" begin
        results = Int64[]
        
        handler = TimerHandler(results) do client, now, timer_id
            push!(client, timer_id)
            return true
        end
        
        # Simulate timer expiry
        @test handler.on_expiry(handler.clientd, 1000, 12345) == true
        @test length(results) == 1
        @test results[1] == 12345
    end
    
    @testset "TimerHandler Return Values" begin
        # Handler that always returns true (continue)
        continue_handler = TimerHandler(nothing) do client, now, timer_id
            return true
        end
        @test continue_handler.on_expiry(continue_handler.clientd, 1000, 1) == true
        
        # Handler that always returns false (stop)
        stop_handler = TimerHandler(nothing) do client, now, timer_id
            return false
        end
        @test stop_handler.on_expiry(stop_handler.clientd, 1000, 1) == false
        
        # Handler with conditional logic
        conditional_handler = TimerHandler(nothing) do client, now, timer_id
            return timer_id % 2 == 0
        end
        @test conditional_handler.on_expiry(conditional_handler.clientd, 1000, 2) == true
        @test conditional_handler.on_expiry(conditional_handler.clientd, 1000, 3) == false
    end
    
end
