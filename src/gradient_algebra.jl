############################ Gradient Algebra ##################################
################################### Sum ########################################
# allocates space for gradient kernel evaluation but does not evaluate
# the separation from evaluation is useful for ValueGradientKernel
function gradient_kernel(k::Sum, x, y, ::GenericInput)
    H = [gradient_kernel(h, x, y, input_trait(h)) for h in k.args]
    LazyMatrixSum(H)
end

# NOTE: K should have been previously allocated with gradient_kernel(k, x, y)
function gradient_kernel!(K::LazyMatrixSum, k::Sum, x::AbstractVector, y::AbstractVector, ::GenericInput)
    for i in eachindex(k.args)
        h = k.args[i]
        K.args[i] = gradient_kernel!(K.args[i], h, x, y, input_trait(h))
    end
    return K
end

################################ Product #######################################
# for product kernel with generic input
function allocate_gradient_kernel(k::Product, x, y, ::GenericInput)
    d, r = length(x), length(k.args)
    H = (gradient_kernel(h, x, y, input_trait(h)) for h in k.args)
    T = typeof(k(x, y))
    A = LazyMatrixSum(
                (LazyMatrixProduct(Diagonal(zeros(T, d)), h) for h in H)...
                )
    U = zeros(T, (d, r)) # storage for Jacobian
    V = zeros(T, (d, r))
    C = Woodbury((-I)(r), ones(r), ones(r)')
    W = Woodbury(A, U, C, V')
end
function gradient_kernel(k::Product, x, y, ::GenericInput)
    W = allocate_gradient_kernel(k, x, y, GenericInput())
    gradient_kernel!(W, k, x, y, GenericInput())
end

# IDEA: could have kernel element for heterogeneous product kernels, problem: would need to
# pre-allocate storage for Jacobian matrix or be allocating
# struct ProductGradientKernelElement{T, K, X, Y} <: Factorization{T}
#     k::K
#     x::X
#     y::Y
# end
function gradient_kernel!(W::Woodbury, k::Product, x::AbstractVector, y::AbstractVector, ::GenericInput = input_trait(k))
    A = W.A # this is a LazyMatrixSum of LazyMatrixProducts
    prod_k_j = k(x, y)

    # k_vec(x, y) = [h(x, y) for h in k.args] # include in loop
    # ForwardDiff.jacobian!(W.U', z->k_vec(z, y), x) # this is actually less allocating than the gradient! option
    # ForwardDiff.jacobian!(W.V, z->k_vec(x, z), y)
    # GradientConfig() # for generic version, this could be pre-computed for efficiency gains
    r = length(k.args)
    for i in 1:r # parallelize this?
        h, H = k.args[i], A.args[i]
        hxy = h(x, y)
        D = H.args[1]
        D.diag .= prod_k_j / hxy
        # input_trait(h) could be pre-computed, or should not be passed here, because the factors might be composite kernels themselves
        H.args[2] = gradient_kernel!(H.args[2], h, x, y, input_trait(h))

        ui, vi = @views W.U[:, i], W.V[i, :]
        ForwardDiff.gradient!(ui, z->h(z, y), x) # these are bottlenecks
        ForwardDiff.gradient!(vi, z->h(x, z), y) # TODO: replace by value_gradient_covariance!
        @. ui *= prod_k_j / hxy
        @. vi /= hxy
    end
    return W
end

############################# Separable Product ################################
# for product kernel with generic input
function allocate_gradient_kernel(k::SeparableProduct, x::AbstractVector{<:Number},
                                  y::AbstractVector{<:Number}, ::GenericInput)
    d = length(x)
    H = (allocate_gradient_kernel(h, x, y, input_trait(h)) for h in k.args)
    T = typeof(k(x, y))
    A = LazyMatrixProduct(Diagonal(zeros(T, d)), Diagonal(zeros(T, d)))
    U = Diagonal(zeros(T, d))
    V = Diagonal(zeros(T, d))
    r = length(k.args)
    d == r || throw(DimensionMismatch("d = $d ≠ $r = r where r is number of product kernel constituents"))
    C = Woodbury((-1I)(r), ones(r), ones(r)')
    Woodbury(A, U, C, V)
end
function gradient_kernel(k::SeparableProduct, x, y, ::GenericInput)
    W = allocate_gradient_kernel(k, x, y, GenericInput())
    gradient_kernel!(W, k, x, y, GenericInput())
end

function gradient_kernel!(W::Woodbury, k::SeparableProduct, x::AbstractVector, y::AbstractVector, ::GenericInput = input_trait(k))
    A = W.A # this is a LazyMatrixProducts of Diagonals
    prod_k_j = k(x, y)
    D, H = A.args # first is scaling matrix by leave_one_out_products, second is diagonal of derivative kernels
    for (i, ki) in enumerate(k.args)
        xi, yi = x[i], y[i]
        kixy = ki(xi, yi)
        # D[i, i] = prod_k_j / kixy
        D[i, i] = ki(xi, yi)
        W.U[i, i] = ForwardDiff.derivative(z->ki(z, yi), xi)
        W.V[i, i] = ForwardDiff.derivative(z->ki(xi, z), yi)
        W.U[i, i] *= prod_k_j / kixy
        W.V[i, i] /= kixy
        H[i, i] = DerivativeKernel(ki)(xi, yi)
    end
    leave_one_out_products!(D.diag)
    return W
end

############################# Separable Sum ####################################
# IDEA: implement block separable with x::AbstractVecOfVec
function allocate_gradient_kernel(k::SeparableSum, x::AbstractVector{<:Number},
                                  y::AbstractVector{<:Number}, ::GenericInput)
    f, h, d = k.f, k.k, length(x)
    H = allocate_gradient_kernel(h, x, y, input_trait(h))
    D = Diagonal(d)
end

function gradient_kernel!(D::Diagonal, k::SeparableSum, x::AbstractVector{<:Number},
                          y::AbstractVector{<:Number}, ::GenericInput)
    for (i, ki) in enumerate(k.args)
        D[i, i] = DerivativeKernel(ki)(x[i], y[i])
    end
    return D
end

############################## Input Transformations ###########################
# can be most efficiently represented by factoring out the Jacobian w.r.t. input warping
function gramian(G::GradientKernel{<:Real, <:Warped},  x::AbstractVector, y::AbstractVector)
    W = G.k
    U(x) = BlockFactorization(Diagonal([ForwardDiff.jacobian(W.u, xi) for xi in x]))
    k = GradientKernel(W.k)
    LazyMatrixProduct(U(x)', gramian(k, x, y), U(y))
end

function gramian(G::GradientKernel{<:Real, <:ScaledInputKernel},  x::AbstractVector, y::AbstractVector)
    n, m = length(x), length(y)
    S = G.k
    Ux = kronecker(I(n), S.U)
    Uy = n == m ? Ux : kronecker(I(m), S.U)
    k = GradientKernel(S.k)
    LazyMatrixProduct(Ux', gramian(k, x, y), Uy)
end

# I don't think this needs a special case, since we can take care of it in
# function gramian(G::GradientKernel{<:Real, <:Lengthscale}, x::AbstractVector, y::AbstractVector)
#     n, m = length(x), length(y)
#     L = G.k
#     Ux = Diagonal(fill(L.l, d*n)) # IDEA: Fill for lazy uniform array
#     Uy = n == m ? Ux : Diagonal(fill(L.l, d*m))
#     k = GradientKernel(L.k)
#     LazyMatrixProduct(Ux', gramian(k, x, y), Uy)
# end

############################### VerticalRescaling ##############################
# gradient element can be expressed with WoodburyIdentity and LazyMatrixProduct
function allocate_gradient_kernel(k::VerticalRescaling, x, y, ::GenericInput = GenericInput())
    f, h, d = k.f, k.k, length(x)
    H = allocate_gradient_kernel(h, x, y, input_trait(h))
    A = LazyMatrixProduct(Diagonal(fill(f(x), d)), H, Diagonal(fill(f(y), d)))
    U = zeros(d, 2)
    V = zeros(d, 2)
    C = zeros(2, 2)
    Woodbury(A, U, C, V')
end

function gradient_kernel!(W::Woodbury, k::VerticalRescaling, x, y, ::GenericInput = GenericInput())
    f, h, A = k.f, k.k, W.A
    fx, fy = f(x), f(y)
    @. A.args[1].diag = fx
    H = A.args[2] # LazyMatrixProduct: first and third are the diagonal scaling matrices, second is the gradient_kernel_matrix of h
    @. A.args[3].diag = fy
    A.args[2] = gradient_kernel!(H, h, x, y, input_trait(h))
    ForwardDiff.gradient!(@view(W.U[:, 1]), f, x)
    ForwardDiff.gradient!(@view(W.U[:, 2]), z->h(z, y), x)
    ForwardDiff.gradient!(@view(W.V[1, :]), f, y)
    ForwardDiff.gradient!(@view(W.V[2, :]), z->h(x, z), y)
    W.C[1, 1] = h(x, y)
    W.C[1, 2] = fy
    W.C[2, 1] = fx
    return W
end

############################ Scalar Chain Rule #################################
# generic implementation of scalar chain rule, does not require input kernel to have a basic input type
# gradient element can be expressed with WoodburyIdentity and LazyMatrixProduct
function allocate_gradient_kernel(k::Chained, x, y, ::GenericInput)
    f, h, d = k.f, k.k, length(x)
    H = allocate_gradient_kernel(h, x, y, input_trait(h))
    A = LazyMatrixProduct(Diagonal(fill(f(h(x, y)), d)), H)
    U = zeros(d, 1)
    V = zeros(d, 1)
    C = zeros(1, 1)
    Woodbury(A, U, C, V')
end

function gradient_kernel!(W::Woodbury, k::Chained, x, y, ::GenericInput)
    f, h, A = k.f, k.k, W.A
    f1, f2 = derivative_laplacian(f, h(x, y))
    @. A.args[1].diag = f1
    H = A.args[2] # LazyMatrixProduct: first argument is diagonal scaling, second is the gradient_kernel_matrix of h
    H.A.args[2] = gradient_kernel!(H, h, x, y, input_trait(h))
    ForwardDiff.gradient!(@view(W.U[:]), z->h(z, y), x)
    ForwardDiff.gradient!(@view(W.V[1, :]), z->h(x, z), y)
    @. W.C = f2
    return W
end
