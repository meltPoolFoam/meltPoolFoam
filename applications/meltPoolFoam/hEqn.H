using constant::mathematical::twoPi;
using constant::physicoChemical::R;     // universal gas constant
using constant::physicoChemical::sigma; // Stefan--Boltzmann constant

const volScalarField& Tsurf = mixture.Tsurf();
radiativeCooling = emissivity*sigma*(pow4(T) - pow4(ambientTemperature));
evaporativeCooling =
    evaporationCoeff*mixture.vapourPressure(ambientPressure)*Hvap*Foam::sqrt(molarMass/twoPi/R/Tsurf);

const volScalarField& redistribution = mixture.surfaceHeatSourceRedistribution();
const volScalarField magGradAlphaM = mag(mixture.gradAlphaM());
const volScalarField evaporativeCoolingPrime = evaporativeCooling*molarMass*Hvap/R/Cp/sqr(Tsurf);

#include "gradT.H"

energySource =
(
  - fvc::laplacian(kappaByRhoCp*hDeltaRhoSolidLiquid, liquidFraction)
  - fvc::laplacian(kappaByRhoCp*hDeltaRhoGasSolid, alpha1)
  + (*laserHeatSource)()
  - redistribution*magGradAlphaM*(radiativeCooling + evaporativeCooling)
)/rho;

fvScalarMatrix hEqn
(
    fvm::ddt(rho, h)
  + fvm::div(rhoPhi, h)
  - fvm::Sp(contErr, h)
 ==
    fvm::laplacian(rhof*kappaByRhoCp, h)
  + rho*energySource
  + redistribution*magGradAlphaM
   *(evaporativeCoolingPrime*h - fvm::Sp(evaporativeCoolingPrime, h))
  //+ fvc::div(rho*U & turbulence->devReff())
);
hEqn.solve();
pp(h);
pp(T);

if (gMin(h) < 0)
{
    runTime.writeNow();
    returnReduceOr(true);   // MPI barrier
    FatalError
        << "Enthalpy becomes negative!"
        << exit(FatalError);
}

mixture.correctThermo();
