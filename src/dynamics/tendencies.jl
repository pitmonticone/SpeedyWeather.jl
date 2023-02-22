function get_tendencies!(   diagn::DiagnosticVariablesLayer,
                            model::BarotropicModel,
                            )
    
    # only (absolute) vorticity advection for the barotropic model
    vorticity_flux_divcurl!(diagn,model,curl=false)         # = -∇⋅(u(ζ+f),v(ζ+f))
end

function get_tendencies!(   diagn::DiagnosticVariablesLayer,
                            surface::SurfaceVariables,
                            pres::LowerTriangularMatrix,    # spectral pressure/η for geopotential
                            time::DateTime,                 # time to evaluate the tendencies at
                            model::ShallowWaterModel,       # struct containing all constants
                            )

    S,C = model.spectral_transform, model.constants

    # for compatibility with other ModelSetups pressure pres = interface displacement η here
    vorticity_flux_divcurl!(diagn,model,curl=true)  # = -∇⋅(u(ζ+f),v(ζ+f)), tendency for vorticity
                                                    # and ∇×(u(ζ+f),v(ζ+f)), tendency for divergence
    geopotential!(diagn,pres,C)                     # Φ = gη in the shallow water model
    bernoulli_potential!(diagn,S)                   # = -∇²(E+Φ), tendency for divergence
    volume_flux_divergence!(diagn,surface,model)    # = -∇⋅(uh,vh), tendency pressure

    # interface forcing
    @unpack interface_relaxation = model.parameters
    interface_relaxation && interface_relaxation!(pres,surface,time,model)
end

function get_tendencies!(   diagn::DiagnosticVariables,
                            progn::PrognosticVariables,
                            time::DateTime,
                            model::PrimitiveEquation,
                            lf::Int=2                   # leapfrog index to evaluate tendencies on
                            )

    B = model.boundaries
    G = model.geometry
    S = model.spectral_transform
    @unpack surface = diagn

    # for semi-implicit corrections (α >= 0.5) linear gravity-wave related tendencies are
    # evaluated at previous timestep i-1 (i.e. lf=1 leapfrog time step) 
    # nonlinear terms and parameterizations are always evaluated at lf
    lf_linear = model.parameters.implicit_α == 0 ? lf : lf

    # PARAMETERIZATIONS
    # parameterization_tendencies!(diagn,time,model)
 
    # DYNAMICS
    pressure_gradients!(diagn,progn,lf,S)               # calculate ∇ln(pₛ)

    for layer in diagn.layers
        thickness_weighted_divergence!(layer,surface,G)    # calculate Δσₖ[(uₖ,vₖ)⋅∇ln(pₛ) + ∇⋅(uₖ,vₖ)]
    end

    geopotential!(diagn,B,G)                        # from ∂Φ/∂ln(pₛ) = -RTᵥ
    vertical_averages!(diagn,progn,lf,G)            # get ū,v̄,D̄ and others
    surface_pressure_tendency!(surface,model)       # ∂ln(pₛ)/∂t = -(ū,v̄)⋅∇ln(pₛ) - ∇⋅(ū,v̄)

    for layer in diagn.layers
        vertical_velocity!(layer,surface,model)     # calculate σ̇ for the vertical mass flux M = pₛσ̇
    end

    vertical_advection!(diagn,model)                # use σ̇ for the vertical advection of u,v,T,q

    for layer in diagn.layers
        vordiv_tendencies!(layer,surface,model)     # vorticity advection
        temperature_tendency!(layer,model)          # hor. advection + adiabatic term
        humidity_tendency!(layer,model)             # horizontal advection of humid
        
        # SPECTRAL TENDENCIES
        spectral_tendencies!(layer,progn,model,lf_linear)

        bernoulli_potential!(layer,S)               # add -∇²(E+ϕ+RTₖlnpₛ) term to div tendency
    end
end

function spectral_tendencies!(  diagn::DiagnosticVariablesLayer,
                                progn::PrognosticVariables,
                                model::PrimitiveEquation,
                                lf::Int)            # leapfrog index to evaluate tendencies on
    
    @unpack R_dry = model.constants
    @unpack temp_ref_profile = model.geometry
    Tₖ = temp_ref_profile[diagn.k]                  # reference temperature at layer k      
    pres = progn.pres.leapfrog[lf]
    @unpack div = progn.layers[diagn.k].leapfrog[lf]
    @unpack temp_tend = diagn.tendencies

    # -R_dry*Tₖ*∇²lnpₛ, linear part of the RTᵥ∇lnpₛ pressure gradient term
    # Tₖ being the reference temperature profile, the anomaly term T' = Tᵥ - Tₖ is calculated
    # vordiv_tendencies! include as R_dry*Tₖ*lnpₛ into the geopotential on which the operator
    # -∇² is applied in bernoulli_potential!
    @unpack geopot = diagn.dynamics_variables
    @. geopot += R_dry*Tₖ*pres
    
    # add the +DTₖ term to tend tendency, as +DT' is calculated in grid-point space at time step i
    # but for semi-implicit corrections do +DTₖ with D at leapfrog step lf (i-1, i.e. not centred)
    @. temp_tend += Tₖ*div
end