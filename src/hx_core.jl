################################################################################
# hx_core.jl
# v 0.5 by Richard Fitzhugh
# Last edited on 10/17/2017
#
# This file contains functions for overall heat exchanger analysis using the
# methods found in Fundamentals of Heat and Mass Transfer by Incropera and
# DeWitt, published by John Wiley and Sons, Inc. The book is standard for
# teaching heat and mass trasfer to mechanical and chemical engineers in the
# United States. The chapter (11) and page numbers used in documentation
# refer to the sixth edition but with minor changes could probably be used for
# other editions as well.
#
# This module uses the ϵ-NTU method because it's much more robust numerically
# than the LMTD method. That is, the equations are formulated in terms of the '
# exponential rather than logarithmic functions, so they don't start returning
# NaNs if a numerical solver happens to guess negative temperatures or the like.
################################################################################




@enum hx_type conc_parallel=0 conc_counter=1 st_oneshell=2 st_twoshell=3 Cr_0=4

struct HeatExchanger
    oldshell::Pipe
    shell::Pipe
    tube::Pipe
    n_tubes::Int
    bafflespace::AbstractFloat
    bafflecut::AbstractFloat
    type_::hx_type
end

function HeatExchanger(shell::Pipe, tube::Pipe, ntubes::Integer,
                        bsp, bcut, type_::hx_type)
    farea = shell.flowarea - ntubes * tube.totalarea
    PW = pi*shell.diameter + ntubes*pi*tube.outer_diameter
    Dh = 4*farea/PW
    newshell = Pipe(shell.length, Dh, Dh/2, farea, shell.thickness,
        shell.outer_diameter, shell.outer_radius, shell.totalarea,
        shell.roughness, shell.elevation_change, shell.therm_cond)
    return HeatExchanger(shell, newshell, tube, ntubes, bsp, bcut, type_)
end

"""
The following are implementations of the effectiveness (ϵ) relations for various
heat exchanger geometries. These equations can be found in Incropera and DeWitt,
Table 11.3, page 689 (6th Ed.)
"""
function ϵ_Cp(NTU, Cr)
    top = 1 - exp(-NTU *(1+Cr))
    return top/(1+Cr)
end

function ϵ_Cc(NTU, Cr)

    if Cr==1
        return NTU/(1+NTU)
    end

    top = 1 - exp(-NTU *(1+Cr))
    bottom = 1 - Cr*exp(-NTU *(1+Cr))
    return top/bottom

end

function ϵ_St₁(NTU, Cr)
    term = exp(-NTU * √(1+Cr^2))
    ans = 2/(1 + Cr + √(1+Cr^2) * (1+term)/(1-term))
    return ans
end

function ϵ_Stₙ(NTU, Cr, n=2)
    term = ((1 - ϵ_St₁(NTU, Cr)*Cr) / (1 - ϵ_St₁(NTU, Cr)))^n
    return (term - 1)/(term - Cr)
end

function ϵ_Cr0(NTU, Cr=0)
    return 1 - exp(-NTU)
end

ϵ_functions = Dict(conc_parallel => ϵ_Cp,
                   conc_counter => ϵ_Cc,
                   st_oneshell => ϵ_St₁,
                   st_twoshell => ϵ_Stₙ,
                   Cr_0 => ϵ_Cr0)

function ϵ(NTU, Cr, hx::hx_type)
    return ϵ_functions[hx](NTU, Cr)
end


"""
Heat transfer correlation for liquid metals, applicable for a uniform heat flux
through the heat transfer surface, with Re between 3600 and 90500, and Pe
between 100 and 10000. Proposed by Skupinski et al. in Int. Journal of Heat and
Mass Transfer, Vol 8 p. 937, 1965.
"""
function lm_correlation(astream, Twall)
    return 4.82+0.0185*(astream.tstream.Re*astream.tstream.Pr)^0.827
end

"""
Gneilinski heat transfer correlation.
A workhorse for turbulent convective heat transfer through a tube.
"""
function gneilinski(astream, Twall)
    f = astream.f
    Re  = astream.Re
    Pr = astream.Pr
    top = (f/8)*(Re-1000)*Pr
    bottom = 1+12.7*√(f/8)*(Pr^(2/3)-1)
    return top/bottom
end

"""
Correlation for molten salt flowing through the shell side
of a segmental-baffled shell-and-tube HX. From 
B.-C. Du et al. / International Journal of Heat and Mass Transfer 113 (2017) 456–465
"""
function moltensalt_shell(astream, Twall)
    return 0.0676*  astream.Re^ 0.70413*  astream.Pr^ 0.4
end 


"""
Laminar, fully developed Nusselt correlation for a wall @ const heat flux
"""
function laminar_tube(astream, Twall)
    return 4.36
end 

function get_correlation(r::FlowStream, descriptor="shell")

  sname = r.tstream.subst_.name
  key_ = (sname, descriptor)
  if haskey(correlations, key_)
    return correlations[key_]
  else
    return gneilinski
  end
end

"""
The purpose of this function is to provide an initial estimate of heat exchanger
performance. It calculates the heat exchanger effectiveness from the ϵ-NTU
method but doesn't take into account how the fluid proerties of either stream
change down the length of the exchanger. The outlet conditions obtained from
this analysis are fed as initial guesses to the solver function that appears
later (called hx_performance_solver)
"""
function hx_performance_calcs(hx_::HeatExchanger,
                              shellstream::Stream,
                              tubestream::Stream,
                              scorr::Function, tcorr::Function)
    # scorr and tcorr are the functions that correspond to the shell-side and
    # the tube-side of the heat exchanger, respectively. The user needs to
    # choose them correctly. Automatic assignment of heat transfer correlations
    # is something I would like someday, but will be really hard to do.
    # They must accept the FlowStream object and the wall temp as arguments,
    # and output the Nusselt number.
    # The wall temp because properties at the wall are needed for some 
    # correlations.
    if shellstream.T > tubestream.T
        hot = shellstream
        cold = tubestream
    else
        hot = tubestream
        cold = shellstream
    end

    Chot = hot.ṁ * hot.Cp
    Ccold = cold.ṁ * cold.Cp

    if Chot > Ccold
        Cmin = Ccold
        Cmax = Chot
    else
        Cmin = Chot
        Cmax = Ccold
    end

    Cr = Cmin/Cmax
    Twall = (hot.T+cold.T)/2
    k = hx_.tube.therm_cond((hot.T+cold.T)/2)
    sflow = FlowStream(hx_.shell, shellstream)
    tstr_onetube = Stream(tubestream.subst_, tubestream.ṁ/hx_.n_tubes, tubestream.p, tubestream.T)
    tflow = FlowStream(hx_.tube, tstr_onetube)
    Nu_s = scorr(sflow, Twall)
    h_o = Nu_s*shellstream.k/hx_.shell.diameter
    Nu_t = tcorr(tflow, Twall)
    h_i = Nu_t*tubestream.k/hx_.tube.diameter

    Ai = π*hx_.tube.diameter*hx_.tube.length*hx_.n_tubes
    Ao = π*hx_.tube.outer_diameter*hx_.tube.length*hx_.n_tubes

    R_cond = log(hx_.tube.outer_diameter / hx_.tube.diameter) / (2π*hx_.tube.length*k*hx_.n_tubes)
    UA = 1/(1/(h_o*Ao) + 1/(h_i*Ai) + R_cond)
    NTU = UA/Cmin
    ϵ_ = ϵ(NTU, Cr, hx_.type_)
    qmax = Cmin*(hot.T - cold.T)
    q = ϵ_*qmax
    Th_out = hot.T - q/Chot
    Tc_out = cold.T+ q/Ccold
    println("Heat transferred: ",q," W")

    if hot==shellstream
        hout = Stream(hot.subst_, hot.ṁ, hot.p - sflow.ΔP, Th_out)
        cout = Stream(cold.subst_,cold.ṁ,cold.p- tflow.ΔP, Tc_out)
    else
        hout = Stream(hot.subst_, hot.ṁ, hot.p - tflow.ΔP, Th_out)
        cout = Stream(cold.subst_,cold.ṁ,cold.p- sflow.ΔP, Tc_out)
    end
    return [hout, cout]
end

"""
Function hx_performance_solver
This function takes the preliminary guesses provided by the previous function
hx_performance_calcs and uses them to find a solution
"""
function hx_performance_solver(hx_::HeatExchanger,
                               shellstream::Stream,
                               tubestream::Stream,
                               scorr::Function, tcorr::Function)
    # scorr and tcorr are the functions that correspond to the shell-side and
    # the tube-side of the heat exchanger, respectively. The user needs to
    # choose them correctly. Automatic assignment of heat transfer correlations
    # is something I would like someday, but will be really hard to do.
    # They must accept the FlowStream object and the wall temp as arguments,
    # and output the Nusselt number.
    # The wall temp because properties at the wall are needed for some 
    # correlations.
    out_init = hx_performance_calcs(hx_, shellstream, tubestream, scorr, tcorr)
    hout_g = out_init[1]
    cout_g = out_init[2]
    x0 = [hout_g.T, cout_g.T, hout_g.p, cout_g.p]

    function dummysolve!(guess, fvec)

        if shellstream.T > tubestream.T
            shellhot_flag = true
        else
            shellhot_flag = false
        end

        Tho, Tco, Pho, Pco = guess

        if shellhot_flag
            hot = shellstream
            Pso = Pho
            cold = tubestream
            Pto = Pco
        else
            hot = tubestream
            Pto = Pho
            cold = shellstream
            Pso = Pco
        end

        Th_avg = (hot.T+Tho)/2
        Tc_avg = (cold.T+Tco)/2
        Ph_avg = (hot.p+Pho)/2
        Pc_avg = (cold.p+Pco)/2
        Twall = (Th_avg+Tc_avg)/2

        hot_avg = Stream(hot.subst_, hot.ṁ, Ph_avg, Th_avg)
        cold_avg = Stream(cold.subst_, cold.ṁ, Pc_avg, Tc_avg)

        Chot = hot.ṁ * hot_avg.Cp
        Ccold = cold.ṁ * cold_avg.Cp

        if Chot > Ccold
            Cmin = Ccold
            Cmax = Chot
        else
            Cmin = Chot
            Cmax = Ccold
        end

        Cr = Cmin/Cmax
        k = hx_.tube.therm_cond((hot.T+cold.T)/2)

        if shellhot_flag
            sflow = FlowStream(hx_.shell, hot_avg)
            tflow = FlowStream(hx_.tube, cold_avg)
        else
            sflow = FlowStream(hx_.shell, cold_avg)
            tflow = FlowStream(hx_.tube, hot_avg)
        end
        Nu_s = scorr(sflow, Twall)
        h_o = Nu_s*shellstream.k/hx_.shell.diameter
        Nu_t = tcorr(tflow, Twall)
        h_i = Nu_t*tubestream.k/hx_.tube.diameter

        Ai = π*hx_.tube.diameter*hx_.tube.length*hx_.n_tubes
        Ao = π*hx_.tube.outer_diameter*hx_.tube.length*hx_.n_tubes

        R_cond = log(hx_.tube.outer_diameter / hx_.tube.diameter) / (2π*hx_.tube.length*k*hx_.n_tubes)
        UA = 1/(1/(h_o*Ao) + 1/(h_i*Ai) + R_cond)
        NTU = UA/Cmin
        ϵ_ = ϵ(NTU, Cr, hx_.type_)
        qmax = Cmin*(hot.T - cold.T)
        # The WHOLE POINT of the calculations so far was to get q
        q = ϵ_*qmax

        if shellhot_flag
            hout = Stream(hot.subst_, hot.ṁ, hot.p - sflow.ΔP, Tho)
            cout = Stream(cold.subst_,cold.ṁ,cold.p- tflow.ΔP, Tco)
        else
            hout = Stream(hot.subst_, hot.ṁ, hot.p - tflow.ΔP, Tho)
            cout = Stream(cold.subst_,cold.ṁ,cold.p- sflow.ΔP, Tco)
        end

        # Calculate errors
        # I've chosen to use enthalpy and pressure balances on the two streams
        # as my four equations
        fvec[1] = q - abs(hot.H - hout.H)
        fvec[2] = q - abs(cold.H - cout.H)
        fvec[3] = (shellstream.p - Pso) - sflow.ΔP
        fvec[4] = (tubestream.p - Pto) - tflow.ΔP
    end
    answer = NLsolve.nlsolve(dummysolve!, x0, ftol=2.0)
    return answer
end

#import pipes
#import co2
#function test_hx_init()
#    tube = pipes.pipe(("40", 1.0), "Stainless Steel", 0.8, 0.0)
#    shell = pipes.pipe(("40", 10.0), "Stainless Steel", 0.8, 0.0)
#    testit = hx.HeatExchanger(shell, tube, 15, 0, 0, hx.st_oneshell)
#    hot_ = Stream("Sodium", 2.0, 1.0e5, 900.)
#    #print(hot_)
#    cold_ = Stream("CO₂", 1.0, 7.5e6, 400.)
#    #print(cold_)
#    print(hx_performance_solver(testit, hot_, cold_))
#end

#test_hx_init()
