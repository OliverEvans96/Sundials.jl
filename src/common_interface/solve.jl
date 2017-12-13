macro c_checkflag(ex,verbose=false)
    @assert Base.Meta.isexpr(ex, :call)
    fname = ex.args[1]
    quote
        flag = $(esc(ex))
        if flag < 0 && $(esc(verbose))
            warn($(string(fname, " failed with error code = ")), flag)
        end
        flag
    end
end

## Common Interface Solve Functions

function DiffEqBase.solve{algType<:Union{SundialsODEAlgorithm,SundialsDAEAlgorithm},
                          recompile_flag}(
  prob::Union{AbstractODEProblem,AbstractDAEProblem},
  alg::algType,timeseries=[],ts=[],ks=[],
  recompile::Type{Val{recompile_flag}}=Val{true};
  kwargs...)

  integrator = DiffEqBase.init(prob,alg,timeseries,ts,ks;kwargs...)
  integrator.sol.retcode == :Default ? _sol = solve!(integrator) :
                                       _sol = integrator.sol
  _sol
end

function DiffEqBase.init{uType, tType, isinplace, Method, LinearSolver}(
    prob::AbstractODEProblem{uType, tType, isinplace},
    alg::SundialsODEAlgorithm{Method,LinearSolver},
    timeseries=[], ts=[], ks=[];

    verbose=true,
    callback=nothing, abstol=1/10^6, reltol=1/10^3,
    saveat=Float64[], tstops=Float64[],
    maxiter=Int(1e5),
    dt = nothing, dtmin = 0.0, dtmax = 0.0,
    timeseries_errors=true,
    dense_errors = false,
    save_everystep=isempty(saveat), dense = save_everystep,
    save_start = true, save_end = true,
    save_timeseries = nothing,
    userdata=nothing,
    kwargs...)

    if verbose
        warned = !isempty(kwargs) && check_keywords(alg, kwargs, warnlist)
        if !(typeof(prob.f) <: AbstractParameterizedFunction) && typeof(alg) <: CVODE_BDF
            if has_tgrad(prob.f)
                warn("Explicit t-gradient given to this stiff solver is ignored.")
                warned = true
            end
        end
        warned && warn_compat()
    end

    if prob.mass_matrix != I
        error("This solver is not able to use mass matrices.")
    end

    callbacks_internal = CallbackSet(callback,prob.callback)

    tspan = prob.tspan
    t0 = tspan[1]

    tdir = sign(tspan[2]-tspan[1])

    tstops_internal, saveat_internal =
      tstop_saveat_disc_handling(tstops,saveat,tdir,tspan,tType)

    if typeof(prob.u0) <: Number
        u0 = [prob.u0]
    else
        u0 = vec(deepcopy(prob.u0))
    end

    sizeu = size(prob.u0)

    ### Fix the more general function to Sundials allowed style
    if !isinplace && (typeof(prob.u0)<:Vector{Float64} || typeof(prob.u0)<:Number)
        f! = (t, u, du) -> (du .= prob.f(t, u); 0)
    elseif !isinplace && typeof(prob.u0)<:AbstractArray
        f! = (t, u, du) -> (du .= vec(prob.f(t, reshape(u, sizeu))); 0)
    elseif typeof(prob.u0)<:Vector{Float64}
        f! = prob.f
    else # Then it's an in-place function on an abstract array
        f! = (t, u, du) -> (prob.f(t, reshape(u, sizeu),reshape(du, sizeu));
                            u = vec(u); du=vec(du); 0)
    end

    if typeof(alg) <: CVODE_BDF
        alg_code = CV_BDF
    elseif typeof(alg) <:  CVODE_Adams
        alg_code = CV_ADAMS
    end

    if Method == :Newton
        method_code = CV_NEWTON
    elseif Method ==  :Functional
        method_code = CV_FUNCTIONAL
    end

    mem_ptr = CVodeCreate(alg_code, method_code)
    (mem_ptr == C_NULL) && error("Failed to allocate CVODE solver object")
    mem = Handle(mem_ptr)

    !verbose && CVodeSetErrHandlerFn(mem,cfunction(null_error_handler, Void,
                                    (Cint, Char,
                                    Char, Ptr{Void})),C_NULL)

    ures  = Vector{uType}()
    dures = Vector{uType}()
    save_start ? ts = [t0] : ts = Float64[]

    userfun = FunJac(f!,(t,u,J) -> f!(Val{:jac},t,u,J))
    u0nv = NVector(u0)
    flag = @c_checkflag CVodeInit(mem,
                                cfunction(cvodefunjac, Cint,
                                          (realtype, N_Vector,
                                           N_Vector, Ref{typeof(userfun)})),
                                t0, convert(N_Vector, u0nv)) verbose

    dt != nothing && (flag = @c_checkflag(CVodeSetInitStep(mem, dt),verbose))
    flag = @c_checkflag CVodeSetMinStep(mem, dtmin) verbose
    flag = @c_checkflag CVodeSetMaxStep(mem, dtmax) verbose
    flag = @c_checkflag CVodeSetUserData(mem, userfun) verbose
    flag = @c_checkflag CVodeSStolerances(mem, reltol, abstol) verbose
    flag = @c_checkflag CVodeSetMaxNumSteps(mem, maxiter) verbose
    flag = @c_checkflag CVodeSetMaxOrd(mem, alg.max_order) verbose
    flag = @c_checkflag CVodeSetMaxHnilWarns(mem, alg.max_hnil_warns) verbose
    flag = @c_checkflag CVodeSetStabLimDet(mem, alg.stability_limit_detect) verbose
    flag = @c_checkflag CVodeSetMaxErrTestFails(mem, alg.max_error_test_failures) verbose
    flag = @c_checkflag CVodeSetMaxNonlinIters(mem, alg.max_nonlinear_iters) verbose
    flag = @c_checkflag CVodeSetMaxConvFails(mem, alg.max_convergence_failures) verbose

    if Method == :Newton # Only use a linear solver if it's a Newton-based method
        if LinearSolver == :Dense
            flag = @c_checkflag CVDense(mem, length(u0)) verbose
        elseif LinearSolver == :Banded
            flag = @c_checkflag CVBand(mem,length(u0), alg.jac_upper, alg.jac_lower) verbose
        elseif LinearSolver == :Diagonal
            flag = @c_checkflag CVDiag(mem) verbose
        elseif LinearSolver == :GMRES
            flag = @c_checkflag CVSpgmr(mem, PREC_NONE, alg.krylov_dim) verbose
        elseif LinearSolver == :BCG
            flag = @c_checkflag CVSpgmr(mem, PREC_NONE, alg.krylov_dim) verbose
        elseif LinearSolver == :TFQMR
            flag = @c_checkflag CVSptfqmr(mem, PREC_NONE, alg.krylov_dim) verbose
        end
    end

    if has_jac(prob.f)
      jac = cfunction(cvodejac,
                      Cint,
                      (Clong,
                       realtype,
                       N_Vector,
                       N_Vector,
                       DlsMat,
                       Ref{typeof(userfun)},
                       N_Vector,
                       N_Vector,
                       N_Vector))
      flag = @c_checkflag CVodeSetUserData(mem, userfun) verbose
      flag = @c_checkflag CVDlsSetDenseJacFn(mem, jac) verbose
    else
        jac = nothing
    end

    utmp = NVector(copy(u0))
    callback == nothing ? tmp = nothing : tmp = similar(u0)
    callback == nothing ? uprev = nothing : uprev = similar(u0)
    tout = [tspan[1]]

    if save_start
      save_value!(ures,u0,uType,sizeu)
      if dense
        f!(tspan[1],u0,utmp)
        save_value!(dures,utmp,uType,sizeu)
      end
    end

    sol = build_solution(prob, alg, ts, ures,
                   dense = dense,
                   du = dures,
                   interp = dense ? DiffEqBase.HermiteInterpolation(ts,ures,dures) :
                                    DiffEqBase.LinearInterpolation(ts,ures),
                   timeseries_errors = timeseries_errors,
                   calculate_error = false)
    opts = DEOptions(saveat_internal,tstops_internal,save_everystep,dense,
                     timeseries_errors,dense_errors,save_end,
                     callbacks_internal,verbose)
    CVODEIntegrator(utmp,t0,t0,mem,sol,alg,f!,userfun,jac,opts,
                       tout,tdir,sizeu,false,tmp,uprev,Cint(flag))
end # function solve

function tstop_saveat_disc_handling(tstops,saveat,tdir,tspan,tType)
  tstops_vec = vec(collect(tType,Iterators.filter(x->tdir*tspan[1]<tdir*x≤tdir*tspan[end],Iterators.flatten((tstops,tspan[end])))))

  if tdir>0
    tstops_internal = binary_minheap(tstops_vec)
  else
    tstops_internal = binary_maxheap(tstops_vec)
  end

  if typeof(saveat) <: Number
    if (tspan[1]:saveat:tspan[end])[end] == tspan[end]
      saveat_vec = convert(Vector{tType},collect(tType,tspan[1]+saveat:saveat:tspan[end]))
    else
      saveat_vec = convert(Vector{tType},collect(tType,tspan[1]+saveat:saveat:(tspan[end]-saveat)))
    end
  else
    saveat_vec = vec(collect(tType,Iterators.filter(x->tdir*tspan[1]<tdir*x<tdir*tspan[end],saveat)))
  end

  if tdir>0
    saveat_internal = binary_minheap(saveat_vec)
  else
    saveat_internal = binary_maxheap(saveat_vec)
  end

  tstops_internal,saveat_internal
end

function DiffEqBase.solve!(integrator::AbstractSundialsIntegrator)
    uType = eltype(integrator.sol.u)
    while !isempty(integrator.opts.tstops)
        tstop = handle_tstop(integrator)
        while integrator.tdir*integrator.t < integrator.tdir*tstop
            integrator.tprev = integrator.t
            if !(typeof(integrator.opts.callback.continuous_callbacks)<:Tuple{})
                integrator.uprev .= integrator.u
            end
            solver_step(integrator,tstop)
            integrator.t = first(integrator.tout)
            if integrator.flag < 0
                integrator.opts.verbose && warn("Integration step exited early due to flag $(integrator.flag)")
                break
            end
            handle_callbacks!(integrator)
            if integrator.flag < 0
                integrator.opts.verbose && warn("Integration step exited early at interpolation due to flag $(integrator.flag)")
                break
            end
        end
        (integrator.flag < 0) && break
    end



    if integrator.opts.save_end && integrator.sol.t[end] != integrator.t
        save_value!(integrator.sol.u,integrator.u,uType,integrator.sizeu)
        push!(integrator.sol.t, integrator.t)
        if integrator.opts.dense
          integrator(integrator.u,integrator.t,Val{1})
          save_value!(integrator.sol.interp.du,integrator.u,uType,integrator.sizeu)
        end
    end

    empty!(integrator.mem);
    if has_analytic(integrator.sol.prob.f)
        calculate_solution_errors!(integrator.sol;
        timeseries_errors=integrator.opts.timeseries_errors,
        dense_errors=integrator.opts.dense_errors)
    end
    solution_new_retcode(integrator.sol,interpret_sundials_retcode(integrator.flag))
end

function handle_tstop(integrator::AbstractSundialsIntegrator)
    tstop = pop!(integrator.opts.tstops)
    set_stop_time(integrator,tstop)
    tstop
end

## Solve for DAEs uses IDA

function DiffEqBase.init{uType, duType, tType, isinplace, LinearSolver}(
    prob::AbstractDAEProblem{uType, duType, tType, isinplace},
    alg::SundialsDAEAlgorithm{LinearSolver},
    timeseries=[], ts=[], ks=[];

    verbose=true,
    dt=nothing, dtmax=0.0,
    save_start=true,
    callback=nothing, abstol=1/10^6, reltol=1/10^3,
    saveat=Float64[], tstops=Float64[], maxiter=Int(1e5),
    timeseries_errors=true,
    dense_errors = false,
    save_everystep=isempty(saveat), dense=save_everystep,
    save_timeseries=nothing, save_end = true,
    userdata=nothing,
    kwargs...)

    if verbose
        warned = !isempty(kwargs) && check_keywords(alg, kwargs, warnida)
        if !(typeof(prob.f) <: AbstractParameterizedFunction)
            if has_tgrad(prob.f)
                warn("Explicit t-gradient given to this stiff solver is ignored.")
                warned = true
            end
        end
        warned && warn_compat()
    end

    callbacks_internal = CallbackSet(callback,prob.callback)

    tspan = prob.tspan
    t0 = tspan[1]

    tdir = sign(tspan[2]-tspan[1])

    tstops_internal, saveat_internal =
      tstop_saveat_disc_handling(tstops,saveat,tdir,tspan,tType)

    if typeof(prob.u0) <: Number
        u0 = [prob.u0]
    else
        u0 = vec(deepcopy(prob.u0))
    end

    if typeof(prob.du0) <: Number
        du0 = [prob.du0]
    else
        du0 = vec(deepcopy(prob.du0))
    end

    sizeu = size(prob.u0)
    sizedu = size(prob.du0)

    ### Fix the more general function to Sundials allowed style
    if !isinplace && (typeof(prob.u0)<:Vector{Float64} || typeof(prob.u0)<:Number)
        f! = (t, u, du, out) -> (out[:] = prob.f(t, u, du); 0)
    elseif !isinplace && typeof(prob.u0)<:AbstractArray
        f! = (t, u, du, out) -> (out[:] = vec(prob.f(t, reshape(u, sizeu),
                                 reshape(du, sizedu)));0)
    elseif typeof(prob.u0)<:Vector{Float64}
        f! = prob.f
    else # Then it's an in-place function on an abstract array
        f! = (t, u, du, out) -> (prob.f(t, reshape(u, sizeu),
                                 reshape(du, sizedu), out);
                                 u = vec(u); du=vec(du); 0)
    end

    mem_ptr = IDACreate()
    (mem_ptr == C_NULL) && error("Failed to allocate IDA solver object")
    mem = Handle(mem_ptr)

    !verbose && IDASetErrHandlerFn(mem,cfunction(null_error_handler, Void,
                                    (Cint, Char,
                                    Char, Ptr{Void})),C_NULL)

    ures = Vector{uType}()
    dures = Vector{uType}()
    ts   = [t0]


    userfun = FunJac(f!,(t,u,du,gamma,J) -> f!(Val{:jac},t,u,du,gamma,J))
    u0nv = NVector(u0)
    flag = @c_checkflag IDAInit(mem, cfunction(idasolfun,
                                             Cint, (realtype, N_Vector, N_Vector,
                                                    N_Vector, Ref{typeof(userfun)})),
                              t0, convert(N_Vector, u0),
                              convert(N_Vector, du0)) verbose
    dt != nothing && (flag = @c_checkflag(IDASetInitStep(mem, dt),verbose))
    flag = @c_checkflag IDASetUserData(mem, userfun) verbose
    flag = @c_checkflag IDASetMaxStep(mem, dtmax) verbose
    flag = @c_checkflag IDASStolerances(mem, reltol, abstol) verbose
    flag = @c_checkflag IDASetMaxNumSteps(mem, maxiter) verbose
    flag = @c_checkflag IDASetMaxOrd(mem,alg.max_order) verbose
    flag = @c_checkflag IDASetMaxErrTestFails(mem,alg.max_error_test_failures) verbose
    flag = @c_checkflag IDASetNonlinConvCoef(mem,alg.nonlinear_convergence_coefficient) verbose
    flag = @c_checkflag IDASetMaxNonlinIters(mem,alg.max_nonlinear_iters) verbose
    flag = @c_checkflag IDASetMaxConvFails(mem,alg.max_convergence_failures) verbose
    flag = @c_checkflag IDASetNonlinConvCoefIC(mem,alg.nonlinear_convergence_coefficient_ic) verbose
    flag = @c_checkflag IDASetMaxNumStepsIC(mem,alg.max_num_steps_ic) verbose
    flag = @c_checkflag IDASetMaxNumJacsIC(mem,alg.max_num_jacs_ic) verbose
    flag = @c_checkflag IDASetMaxNumItersIC(mem,alg.max_num_iters_ic) verbose
    #flag = @c_checkflag IDASetMaxBacksIC(mem,alg.max_num_backs_ic) verbose # Needs newer version?
    flag = @c_checkflag IDASetLineSearchOffIC(mem,alg.use_linesearch_ic) verbose

    if LinearSolver == :Dense
        flag = @c_checkflag IDADense(mem, length(u0)) verbose
    elseif LinearSolver == :Band
        flag = @c_checkflag IDABand(mem, length(u0), alg.jac_upper, alg.jac_lower) verbose
    elseif LinearSolver == :Diagonal
        flag = @c_checkflag IDADiag(mem) verbose
    elseif LinearSolver == :GMRES
        flag = @c_checkflag IDASpgmr(mem, PREC_NONE, alg.krylov_dim) verbose
    elseif LinearSolver == :BCG
        flag = @c_checkflag IDASpgmr(mem, PREC_NONE, alg.krylov_dim) verbose
    elseif LinearSolver == :TFQMR
        flag = @c_checkflag IDASptfqmr(mem, PREC_NONE, alg.krylov_dim) verbose
    end

    if has_jac(prob.f)
      jac = cfunction(idajac,
                      Cint,
                      (Clong,
                       realtype,
                       realtype,
                       N_Vector,
                       N_Vector,
                       N_Vector,
                       DlsMat,
                       Ref{typeof(userfun)},
                       N_Vector,
                       N_Vector,
                       N_Vector))
      flag = @c_checkflag IDASetUserData(mem, userfun) verbose
      flag = @c_checkflag IDADlsSetDenseJacFn(mem, jac) verbose
    else
      jac = nothing
    end

    utmp = NVector(copy(u0))
    dutmp = NVector(copy(u0))
    tout = [tspan[1]]

    rtest = zeros(length(u0))
    f!(t0, u0, du0, rtest)
    if any(abs.(rtest) .>= reltol)
        if prob.differential_vars === nothing
            error("Must supply differential_vars argument to DAEProblem constructor to use IDA initial value solver.")
        end
        flag = @c_checkflag IDASetId(mem, collect(Float64, prob.differential_vars)) verbose
        flag = @c_checkflag IDACalcIC(mem, IDA_YA_YDP_INIT, t0) verbose
    end

    if save_start
      save_value!(ures,u0,uType,sizeu)
      if dense
        save_value!(dures,du0,uType,sizedu) # Does this need to update for IDACalcIC?
      end
    end

    callback == nothing ? tmp = nothing : tmp = similar(u0)
    callback == nothing ? uprev = nothing : uprev = similar(u0)

    if flag >= 0
        retcode = :Default
    else
        retcode = :InitialFailure
    end

    sol = build_solution(prob, alg, ts, ures,
                   dense = dense,
                   du = dures,
                   interp = dense ? DiffEqBase.HermiteInterpolation(ts,ures,dures) :
                                    DiffEqBase.LinearInterpolation(ts,ures),
                   calculate_error = false,
                   timeseries_errors = timeseries_errors,
                   retcode = retcode,
                   dense_errors = dense_errors)

    opts = DEOptions(saveat_internal,tstops_internal,save_everystep,dense,
                    timeseries_errors,dense_errors,save_end,
                    callbacks_internal,verbose)

    IDAIntegrator(utmp,dutmp,t0,t0,mem,sol,alg,f!,userfun,jac,opts,
                   tout,tdir,sizeu,sizedu,false,tmp,uprev,Cint(flag))
end # function solve

## Common calls

function interpret_sundials_retcode(flag)
  flag >= 0 && return :Success
  flag == -1 && return :MaxIters
  (flag == -2 || flag == -3) && return :Unstable
  flag == -4 && return :ConvergenceFailure
  return :Failure
end

function solver_step(integrator::CVODEIntegrator,tstop)
    integrator.flag = CVode(integrator.mem, tstop, integrator.u, integrator.tout, CV_ONE_STEP)
end
function solver_step(integrator::IDAIntegrator,tstop)
    flag = IDASolve(integrator.mem, tstop, integrator.tout, integrator.u, integrator.du, IDA_ONE_STEP)
end
function set_stop_time(integrator::CVODEIntegrator,tstop)
    CVodeSetStopTime(integrator.mem,tstop)
end
function set_stop_time(integrator::IDAIntegrator,tstop)
    IDASetStopTime(integrator.mem,tstop)
end