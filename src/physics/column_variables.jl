"""
$(TYPEDSIGNATURES)
Update `C::ColumnVariables` by copying the prognostic variables from `D::DiagnosticVariables`
at gridpoint index `ij`. Provide `G::Geometry` for coordinate information."""
function get_column!(   C::ColumnVariables,
                        D::DiagnosticVariables,
                        ij::Integer,        # grid point index
                        jring::Integer,     # ring index 1 around North Pole to J around South Pole
                        G::Geometry)

    (;σ_levels_full,ln_σ_levels_full) = G

    @boundscheck C.nlev == D.nlev || throw(BoundsError)

    C.latd = G.latds[ij]      # pull latitude, longitude [˚N,˚E] for gridpoint ij from Geometry
    C.lond = G.londs[ij]
    C.jring = jring           # ring index j of column, used to index latitude vectors

    # pressure [Pa]/[log(Pa)]
    lnpₛ = D.surface.pres_grid[ij]          # logarithm of surf pressure used in dynamics
    pₛ = exp(lnpₛ)                          # convert back here
    C.ln_pres .= ln_σ_levels_full .+ lnpₛ   # log pressure on every level ln(p) = ln(σ) + ln(pₛ)
    C.pres[1:end-1] .= σ_levels_full.*pₛ    # pressure on every level p = σ*pₛ
    C.pres[end] = pₛ                        # last element is surface pressure pₛ

    @inbounds for (k,layer) = enumerate(D.layers)   # read out prognostic variables on grid
        C.u[k] = layer.grid_variables.u_grid[ij]
        C.v[k] = layer.grid_variables.v_grid[ij]
        C.temp[k] = layer.grid_variables.temp_grid[ij]
        C.humid[k] = layer.grid_variables.humid_grid[ij]

        # as well as geopotential (not actually prognostic though)
        # TODO geopot on the grid is currently not computed in dynamics
        C.geopot[k] = layer.grid_variables.geopot_grid[ij]
    end
end

"""Recalculate ring index if not provided."""
function get_column!(   C::ColumnVariables,
                        D::DiagnosticVariables,
                        ij::Int,            # grid point index
                        G::Geometry)

    rings = eachring(G.Grid,G.nlat_half)
    jring = whichring(ij,rings)
    get_column!(C,D,ij,jring,G)
end

"""
$(TYPEDSIGNATURES)
Write the parametrization tendencies from `C::ColumnVariables` into the horizontal fields
of tendencies stored in `D::DiagnosticVariables` at gridpoint index `ij`."""
function write_column_tendencies!(  D::DiagnosticVariables,
                                    C::ColumnVariables,
                                    ij::Int)            # grid point index

    @boundscheck C.nlev == D.nlev || throw(BoundsError)

    @inbounds for (k,layer) = enumerate(D.layers)
        layer.tendencies.u_tend_grid[ij] = C.u_tend[k]
        layer.tendencies.v_tend_grid[ij] = C.v_tend[k]
        layer.tendencies.temp_tend_grid[ij] = C.temp_tend[k]
        layer.tendencies.humid_tend_grid[ij] = C.humid_tend[k]
    end

    # accumulate (set back to zero when netcdf output)
    D.surface.precip_large_scale[ij] += C.precip_large_scale
    D.surface.precip_convection[ij] += C.precip_convection

    return nothing
end

"""
$(TYPEDSIGNATURES)
Set the accumulators (tendencies but also vertical sums and similar) back to zero
for `column` to be reused at other grid points."""
function reset_column!(column::ColumnVariables{NF}) where NF

    # set tendencies to 0 for += accumulation
    column.u_tend .= 0
    column.v_tend .= 0
    column.temp_tend .= 0
    column.humid_tend .= 0

    # set fluxes to 0 for += accumulation
    column.flux_u_upward .= 0
    column.flux_u_downward .= 0
    column.flux_v_upward .= 0
    column.flux_v_downward .= 0
    column.flux_humid_upward .= 0
    column.flux_humid_downward .= 0
    column.flux_temp_upward .= 0
    column.flux_temp_downward .= 0

    # # Convection
    # column.cloud_top = column.nlev+1
    # column.conditional_instability = false
    # column.activate_convection = false
    column.precip_convection = zero(NF)
    # fill!(column.net_flux_humid, 0)
    # fill!(column.net_flux_dry_static_energy, 0)

    # Large-scale condensation
    column.precip_large_scale = zero(NF)
    return nothing
end

# iterator for convenience
eachlayer(column::ColumnVariables) = Base.OneTo(column.nlev)