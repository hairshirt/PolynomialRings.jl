module Operators

import PolynomialRings: leading_term, basering, exptype, base_extend, base_restrict
import PolynomialRings.Monomials: AbstractMonomial
import PolynomialRings.MonomialOrderings: MonomialOrder
import PolynomialRings.Terms: Term, monomial, coefficient
import PolynomialRings.Polynomials: Polynomial, termtype, terms, monomialorder

# -----------------------------------------------------------------------------
#
# Imports for overloading
#
# -----------------------------------------------------------------------------
import Base: zero, one, +, -, *, ==, div, rem, divrem, iszero, diff, ^, gcd
import PolynomialRings: maybe_div

# -----------------------------------------------------------------------------
#
# zero, one, etc
#
# -----------------------------------------------------------------------------
zero(::Type{P}) where P<:Polynomial = P(termtype(P)[])
one(::Type{P})  where P<:Polynomial = P([one(termtype(P))])
zero(::P)       where P <: Polynomial = zero(P)
one(::P)        where P <: Polynomial = one(P)

iszero(a::P)        where P <: Polynomial = length(terms(a)) == 0
==(a::P,b::P)       where P <: Polynomial = a.terms == b.terms
+(a::P)             where P <: Polynomial = a
-(a::P)             where P <: Polynomial = P([-t for t in terms(a)])

# -----------------------------------------------------------------------------
#
# utility for operators
#
# -----------------------------------------------------------------------------
function _collect_summands!(summands::AbstractVector{T}) where T <: Term
    if length(summands) > 0
        last_exp = monomial(summands[1])
        n = 1
        for j in 2:length(summands)
            exponent, coef = monomial(summands[j]), coefficient(summands[j])
            if exponent == last_exp
                cur_coef = coefficient(summands[n])
                @inbounds summands[n] = T(exponent, cur_coef + coef)
            else
                @inbounds summands[n+=1] = summands[j]
                last_exp = exponent
            end
        end
        resize!(summands, n)
        filter!(!iszero, summands)
    end
end

# -----------------------------------------------------------------------------
#
# addition, subtraction
#
# -----------------------------------------------------------------------------
function +(a::Polynomial{A1,Order}, b::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}


    C = promote_type(C1,C2)
    T = Term{M, C}
    P = Polynomial{Vector{T},Order}
    res = Vector{T}(length(a.terms) + length(b.terms))
    n = 0

    state_a = start(terms(a))
    state_b = start(terms(b))
    while !done(terms(a), state_a) && !done(terms(b), state_b)
        (term_a, next_state_a) = next(terms(a), state_a)
        (term_b, next_state_b) = next(terms(b), state_b)
        exponent_a, coefficient_a = monomial(term_a), coefficient(term_a)
        exponent_b, coefficient_b = monomial(term_b), coefficient(term_b)

        if Base.Order.lt(MonomialOrder{Order}(), exponent_a, exponent_b)
            @inbounds res[n+=1] = T(exponent_a, coefficient_a)
            state_a = next_state_a
        elseif Base.Order.lt(MonomialOrder{Order}(), exponent_b, exponent_a)
            @inbounds res[n+=1] = T(exponent_b, coefficient_b)
            state_b = next_state_b
        else
            coeff = coefficient_a + coefficient_b
            if !iszero(coeff)
                @inbounds res[n+=1] = T(exponent_a, coeff)
            end
            state_b = next_state_b
            state_a = next_state_a
        end
    end

    for t in Iterators.rest(terms(a), state_a)
        @inbounds res[n+=1] = base_extend(t, C)
    end
    for t in Iterators.rest(terms(b), state_b)
        @inbounds res[n+=1] = base_extend(t, C)
    end

    resize!(res, n)
    return P(res)
end

function -(a::Polynomial{A1,Order}, b::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}


    C = promote_type(C1,C2)
    T = Term{M, C}
    P = Polynomial{Vector{T},Order}
    res = Vector{T}(length(a.terms) + length(b.terms))
    n = 0

    state_a = start(terms(a))
    state_b = start(terms(b))
    while !done(terms(a), state_a) && !done(terms(b), state_b)
        (term_a, next_state_a) = next(terms(a), state_a)
        (term_b, next_state_b) = next(terms(b), state_b)
        exponent_a, coefficient_a = monomial(term_a), coefficient(term_a)
        exponent_b, coefficient_b = monomial(term_b), coefficient(term_b)

        if Base.Order.lt(MonomialOrder{Order}(), exponent_a, exponent_b)
            @inbounds res[n+=1] = T(exponent_a, coefficient_a)
            state_a = next_state_a
        elseif Base.Order.lt(MonomialOrder{Order}(), exponent_b, exponent_a)
            @inbounds res[n+=1] = -T(exponent_b, coefficient_b)
            state_b = next_state_b
        else
            coeff = coefficient_a - coefficient_b
            if !iszero(coeff)
                @inbounds res[n+=1] = Term(exponent_a, coeff)
            end
            state_b = next_state_b
            state_a = next_state_a
        end
    end

    for t in Iterators.rest(terms(a), state_a)
        @inbounds res[n+=1] = base_extend(t, C)
    end
    for t in Iterators.rest(terms(b), state_b)
        @inbounds res[n+=1] = -base_extend(t, C)
    end

    resize!(res, n)
    return P(res)
end

# -----------------------------------------------------------------------------
#
# multiplication
#
# -----------------------------------------------------------------------------
import PolynomialRings.Util: BoundedHeap
import DataStructures: enqueue!, dequeue!, peek

function *(a::Polynomial{A1,Order}, b::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}


    C = promote_type(C1, C2)
    T = Term{M, C}
    PP = Polynomial{Vector{T}, Order}

    if iszero(a) || iszero(b)
        return zero(PP)
    end

    summands = Vector{T}(length(terms(a)) * length(terms(b)))
    k = 0

    row_indices= zeros(Int, length(terms(a)))
    col_indices= zeros(Int, length(terms(b)))

    # using a bounded queue not to drop items when it gets too big, but to allocate it
    # once to its maximal theoretical size and never reallocate.
    order = Base.Order.Lt((a,b)->Base.Order.lt(MonomialOrder{Order}(), a[3], b[3]))
    minimal_corners = BoundedHeap(Tuple{Int,Int,T}, min(length(terms(a)), length(terms(b))), order)
    @inbounds t = terms(a)[1] * terms(b)[1]
    enqueue!(minimal_corners, (1,1,t))
    @inbounds while length(minimal_corners)>0
        row, col, t = peek(minimal_corners)
        dequeue!(minimal_corners)
        summands[k+=1] = base_extend(t, C)
        row_indices[row] = col
        col_indices[col] = row
        if row < length(terms(a)) && row_indices[row+1] == col - 1
            @inbounds t = terms(a)[row+1] * terms(b)[col]
            enqueue!(minimal_corners, (row+1,col, t))
        end
        if col < length(terms(b)) && col_indices[col+1] == row - 1
            @inbounds t = terms(a)[row] * terms(b)[col+1]
            enqueue!(minimal_corners, (row,col+1, t))
        end
    end

    _collect_summands!(summands)

    return PP(summands)
end

# -----------------------------------------------------------------------------
#
# long division
#
# -----------------------------------------------------------------------------
abstract type RedType end
struct Lead <: RedType end
struct Full <: RedType end
leaddivrem(f::Polynomial, g::Polynomial) = divrem(Lead(), f, g)
divrem(f::Polynomial, g::Polynomial)     = divrem(Full(), f, g)
leadrem(f::Polynomial, g::Polynomial)    = rem(Lead(), f, g)
rem(f::Polynomial, g::Polynomial)        = rem(Full(), f, g)
leaddiv(f::Polynomial, g::Polynomial)    = div(Lead(), f, g)
div(f::Polynomial, g::Polynomial)        = div(Full(), f, g)

function divrem(::Full, f::Polynomial{A1,Order}, g::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}
    if iszero(f)
        return zero(g), f
    end
    if iszero(g)
        throw(DivideError())
    end
    lt_g = leading_term(g)
    for t in @view terms(f)[end:-1:1]
        factor = maybe_div(t, lt_g)
        if !isnull(factor)
            return typeof(f)([factor]), f - factor*g
        end
    end
    return zero(g), f
end

function divrem(::Lead, f::Polynomial{A1,Order}, g::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}
    if iszero(f)
        return zero(g), f
    end
    if iszero(g)
        throw(DivideError())
    end
    lt_f = leading_term(f)
    lt_g = leading_term(g)
    factor = maybe_div(lt_f, lt_g)
    if !isnull(factor)
        return typeof(f)([factor]), f - factor*g
    end
    return zero(g), f
end

function div(redtype::RedType, f::Polynomial{A1,Order}, g::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}
    divrem(redtype, f, g)[1]
end
function rem(redtype::RedType, f::Polynomial{A1,Order}, g::Polynomial{A2,Order}) where A1<:AbstractVector{Term{M,C1}} where A2<:AbstractVector{Term{M,C2}} where M <: AbstractMonomial where {C1, C2, Order}
    divrem(f, g)[2]
end

# -----------------------------------------------------------------------------
#
# exponentiation
#
# -----------------------------------------------------------------------------
function multinomial(n,k...)
    @assert sum(k) == n

    i = 1
    for k_i in k
        i *= binomial(n,k_i)
        n -= k_i
    end
    i
end

function ^(f::Polynomial, n::Integer)
    if n == 0
        return one(f)
    end
    if n == 1
        return f
    end

    T = termtype(f)
    C = basering(f)
    E = exptype(f)
    I = typeof(n)

    N = length(terms(f))

    # need BigInts to do the multinom computation, but we'll cast
    # back to I = typeof(n) when we use it as an exponent
    bign = BigInt(n)
    i = zeros(BigInt, N)
    i[N] = bign

    summands = Vector{T}(Int( multinomial(bign+N-1, N-1, bign) ))
    s = 0

    while true
        # C(multinomial(...)) may raise an InexactError when the coefficient is too big to fit;
        # this is intentional. The suggested fix is for the user to do
        #     base_extend(f, BigInt)^n
        new_coeff = C(multinomial(bign, i...)) * prod(coefficient(f.terms[k])^I(i[k]) for k=1:N)
        new_monom = prod(monomial(f.terms[k])^E(i[k]) for k=1:N)
        summands[s+=1] = T(new_monom, new_coeff)
        carry = 1
        for j = N-1:-1:1
            i[j] += carry
            i[N] -= carry
            if i[N] < 0
                carry = 1
                i[N] += i[j]
                i[j] = 0
            else
                carry = 0
            end
        end
        if carry != 0
            break
        end
    end

    sort!(summands, order=monomialorder(f))

    _collect_summands!(summands)

    return typeof(f)(summands)

end

# -----------------------------------------------------------------------------
#
# differentation
#
# -----------------------------------------------------------------------------
function diff(f::Polynomial, i::Integer)
    iszero(f) && return zero(f)
    new_terms = filter(!iszero, map(t->diff(t,i), terms(f)))
    sort!(new_terms, order=monomialorder(f))
    return typeof(f)(new_terms)
end

# -----------------------------------------------------------------------------
#
# gcds and content
#
# -----------------------------------------------------------------------------
gcd(f::Polynomial, g::Integer) = gcd(g, reduce(gcd, 0, (coefficient(t) for t in terms(f))))
gcd(g::Integer, f::Polynomial) = gcd(g, reduce(gcd, 0, (coefficient(t) for t in terms(f))))

function div(f::Polynomial, g::Integer)
    T = termtype(f)
    P = typeof(f)
    new_terms = [T(monomial(t),div(coefficient(t),g)) for t in terms(f)]
    filter!(!iszero, new_terms)
    return P(new_terms)
end

content(f::Polynomial) = gcd(f, 0)

common_denominator(a) = denominator(a)
common_denominator(a, b) = lcm(denominator(a), denominator(b))
common_denominator(a, b...) = lcm(denominator(a), denominator.(b)...)
common_denominator(f::Polynomial) = iszero(f) ? 1 : lcm([common_denominator(coefficient(t)) for t in terms(f)]...)

function integral_fraction(f::Polynomial)
    D = common_denominator(f)

    return base_restrict(D*f), D
end


# -----------------------------------------------------------------------------
#
# Use Term as a polynomial
#
# -----------------------------------------------------------------------------
function *(a::T, b::P) where P<:Polynomial{V} where V<:AbstractVector{T} where T<:Term
    P([ T(monomial(a) * monomial(t), coefficient(a) * coefficient(t)) for t in terms(b) ])
end
function *(a::P, b::T) where P<:Polynomial{V} where V<:AbstractVector{T} where T<:Term
    P([ T(monomial(t) * monomial(b), coefficient(t) * coefficient(b)) for t in terms(a) ])
end


end
