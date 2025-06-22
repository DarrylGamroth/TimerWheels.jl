module TimerWheels

using FunctionWrappers: FunctionWrapper

export TimerHandler

abstract type AbstractTimerHandler end

const OnExpiryWrapper{C} = FunctionWrapper{Bool, Tuple{C, Int64, Int64}}

struct TimerHandler{C} <: AbstractTimerHandler
    on_expiry::OnExpiryWrapper{C}
    clientd::C
    TimerHandler(f, clientd::C) where {C} = new{C}(OnExpiryWrapper{C}(f), clientd)
end

include("deadlinetimerwheel.jl")

end # module TimerWheels