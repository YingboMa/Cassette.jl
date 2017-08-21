###################
# CodeInfo Lookup #
###################

function lookup_code_info(::Type{S}, arg_names::Vector,
                          debug::Bool = false,
                          world::UInt = typemax(UInt)) where {S<:Tuple}
    if debug
        println("-----------------------------------")
        println("ENCOUNTERED TYPE SIGNATURE: ", S)
    end
    method, code_info = _lookup_code_info(S, arg_names, world)
    debug && println("LOOKED UP METHOD: ", method)
    debug && println("LOOKED UP CODEINFO: ", code_info)
    return code_info
end

function _lookup_code_info(::Type{S}, arg_names::Vector,
                           world::UInt = typemax(UInt)) where {S<:Tuple}
    # retrieve initial Method + CodeInfo
    methods = Base._methods_by_ftype(S, -1, world)
    length(methods) == 1 || return nothing
    type_signature, raw_static_params, method = first(methods)
    method_instance = Core.Inference.code_for_method(method, type_signature, raw_static_params, world, false)
    method_signature = method.sig
    static_params = Any[raw_static_params...]
    code_info = Core.Inference.retrieve_code_info(method_instance)
    isa(code_info, CodeInfo) || return nothing

    # substitute static parameters/varargs
    body = Expr(:block)
    body.args = code_info.code
    if method.isva
        nargs = method.nargs
        new_nargs = length(arg_names) + 1
        new_slotnames = code_info.slotnames[1:(nargs - 1)]
        new_slotflags = code_info.slotflags[1:(nargs - 1)]
        for i in nargs:new_nargs
            push!(new_slotnames, arg_names[i - 1])
            push!(new_slotflags, 0x00)
        end
        append!(new_slotnames, code_info.slotnames[(nargs + 1):end])
        append!(new_slotflags, code_info.slotflags[(nargs + 1):end])
        offset = new_nargs - nargs
        vararg_tuple = Expr(:call, GlobalRef(Core, :tuple), [SlotNumber(i) for i in nargs:new_nargs]...)
        new_slots = Any[SlotNumber(i) for i in 1:(method.nargs - 1)]
        push!(new_slots, vararg_tuple)
        Base.Core.Inference.substitute!(body, new_nargs, new_slots, method_signature, static_params, offset)
        code_info.slotnames = new_slotnames
        code_info.slotflags = new_slotflags
    else
        Base.Core.Inference.substitute!(body, 0, Any[], method_signature, static_params, 0)
    end

    return method, code_info
end


###################################
# Subexpression Match Replacement #
###################################

replace_match!(f, ismatch, x) = x
replace_match!(f, ismatch, code_info::CodeInfo) = (replace_match!(f, ismatch, code_info.code); code_info)
replace_match!(f, ismatch, ast::Expr) = (replace_match!(f, ismatch, ast.args); ast)

function replace_match!(f, ismatch, lines::Array)
    for i in eachindex(lines)
        line = lines[i]
        if ismatch(line)
            lines[i] = f(line)
        else
            replace_match!(f, ismatch, line)
        end
    end
    return lines
end

####################
# Call Replacement #
####################

function is_replaceable_call(x)
    if isa(x, Expr) && (x.head == :call)
        if isa(x.args[1], GlobalRef)
            return x.args[1].mod != Core
        else
            return true
        end
    end
    return false
end

function transform_call!(f, call::Expr)
    call.args[1] = f(replace_calls!(f, call.args[1]))
    for i in 2:length(call.args)
        replace_calls!(f, call.args[i])
    end
    return call
end

replace_calls!(f, x) = replace_match!(call -> transform_call!(f, call), is_replaceable_call, x)

##########################
# SlotNumber Replacement #
##########################

replace_slotnumbers!(f, x) = replace_match!(f, s -> isa(s, SlotNumber), x)

#################
# Miscellaneous #
#################

function is_method_definition(x)
    if isa(x, Expr)
        if x.head == :function
            return true
        elseif x.head == :(=) && isa(x.args[1], Expr)
            lhs = x.args[1]
            if lhs.head == :where
                lhs = lhs.args[1]
            end
            return lhs.head == :call
        end
    end
    return false
end

function replace_signature_callable!(sig, new_callable)
    if sig.head == :where
        sig = sig.args[1]
    end
    sig.args[1] = new_callable
    return sig
end

function extract_callable_from_signature(sig)
    if sig.head == :where
        sig = sig.args[1]
    end
    return sig.args[1]
end

function wrap_signature_callable_type!(signature, T)
    callable = extract_callable_from_signature(signature)
    i = length(callable.args)
    callable.args[i] = :($T{<:$(callable.args[i])})
    return signature
end

function extract_args_from_signature(sig)
    if sig.head == :where
        sig = sig.args[1]
    end
    return view(sig.args, 2:length(sig.args))
end

function is_quoted_symbol(x)
    if isa(x, QuoteNode)
        return true
    elseif isa(x, Expr) && x.head == :quote && length(x.args) == 1
        return isa(x.args[1], Symbol)
    end
    return false
end

function extract_quoted_symbol(x)
    @assert is_quoted_symbol(x)
    if isa(x, QuoteNode)
        return x.value
    elseif isa(x, Expr)
        return x.args[1]
    end
end

get_tls_world_age() = ccall(:jl_get_tls_world_age, UInt, ())

function add_type_variable!(x, T)
    @assert is_method_definition(x)
    if isa(x.args[1], Expr) && x.args[1].head == :where
        push!(x.args[1].args, T)
    else
        x.args = Any[Expr(:where, x.args[1], T), x.args[2]]
    end
    return x
end
