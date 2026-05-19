/*---------------------------------------------------------------------------*\
  =========                 |
  \\      /  F ield         | OpenFOAM: The Open Source CFD Toolbox
   \\    /   O peration     |
    \\  /    A nd           | Copyright held by original author(s)
     \\/     M anipulation  |
-------------------------------------------------------------------------------
                            | Copyright (C) 2020-2023 Oleg Rogozin
-------------------------------------------------------------------------------
License
    This file is part of slmMeltPoolFoam.

    OpenFOAM is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    OpenFOAM is distributed in the hope that it will be useful, but WITHOUT
    ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
    FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
    for more details.

    You should have received a copy of the GNU General Public License
    along with OpenFOAM.  If not, see <http://www.gnu.org/licenses/>.

\*---------------------------------------------------------------------------*/

#include "incompressibleGasMetalMixture.H"

#include "fvc.H"
#include "constants.H"
#include "wallFvPatch.H"

#include "generateGeometricField.H"
#include "updateGeometricField.H"

#include "fvcSmooth.H"
#include "surfaceForces.H"

// * * * * * * * * * * * * * * Static Data Members * * * * * * * * * * * * * //

namespace Foam
{
    defineTypeNameAndDebug(incompressibleGasMetalMixture, 0);

    defineTemplateTypeNameAndDebugWithName
    (
        gasMetalThermalProperties<incompressibleGasMetalMixture>,
        "incompressibleGasMetalThermalProperties",
        0
    );
}


// * * * * * * * * * * * * * * * * Constructors  * * * * * * * * * * * * * * //

Foam::incompressibleGasMetalMixture::incompressibleGasMetalMixture
(
    const volVectorField& U,
    const surfaceScalarField& phi
)
:
    immiscibleIncompressibleTwoPhaseMixture(U, phi),
    gasMetalThermalProperties(U.mesh(), *this),
    surfForcesPtr_(autoPtr<surfaceForces>::New(alphaM_,phi,U,*this)),
    sigmaPtr_(Function1<scalar>::New("sigma", this->subDict("sigma"), &U.mesh())),
    mushyCoeff_("mushyCoeff", dimDensity/dimTime, *this),
    qMushyCoeff_("qMushyCoeff", dimless, *this),
    Tcritical_("Tcritical", dimTemperature, thermo().subDict("metal")),
    metalDict_(subDict("metal")),
    quasiIncompressible_(metalDict_.getOrDefault("quasiIncompressible", false)),
    momentumRedistribution_(metalDict_.getOrDefault("momentumRedistribution", false)),
    evaporationConsidered_(metalDict_.getOrDefault("evaporationConsidered", true)),
    rhoJump_(rho1_.value() - metalDict_.get<scalar>("rhoSolid")),
    initialMass_("initialMass", dimMass, 0),
    tauCorr_("tauCorr",dimTime, metalDict_.get<scalar>("tauCorr")),
    rhoM_(volScalarField::New("rhoM", U.mesh(), rho1_)),
    divPhi_(volScalarField::New("divPhi", U.mesh(), dimensionedScalar(inv(dimTime))))

{
    const scalar Tmelting = thermo().Tmelting().value();
    updateRhoM();
    initialMass_ = fvc::domainIntegrate(rhoM_*alphaM_);

    Info<< "Transport properties:" << endl
        << " -- Surface tension at Tmelting = " << sigmaPtr_->value(Tmelting) << endl
        << " -- Marangoni coefficient at Tmelting = " << dSigmaDT(Tmelting) << endl
        << " -- Gas density = " << rho2_.value() << endl
        << " -- Mass in metal = " << initialMass_ .value()  << endl;

    // Need for DDt in divPhi()
    T().oldTime();
    liquidFraction().oldTime();
    liquidFractionInMetal().oldTime();

    scalar beta = thermo().betaLiquid().value();

    if (!quasiIncompressible_ && (mag(rhoJump_) + mag(beta)) > VSMALL) {
        FatalError <<
            "Mismatch between quasi-incompressible mode and densities difference." << nl
            << "Liquid metal density at Tmeltinqg = " << rhoM(Tmelting, Tmelting, 1) << nl
            << "Solid metal density at Tmelting = " << rhoM(Tmelting, Tmelting, 0) << nl
            << "Thermal expansion coefficient betta = " << beta
            << exit(FatalError);
    }

    Info<< " -- Liquid metal density at " << Tmelting + 1000 << " = "
        << rhoM(Tmelting, Tmelting + 1000, 1) << endl
        << " -- Liquid metal density at Tmelting = " << rhoM(Tmelting, Tmelting, 1) << endl
        << " -- Solid metal density at Tmelting = " << rhoM(Tmelting, Tmelting, 0) << endl
        << " -- Solid metal density at " << Tmelting - 1000 << " = "
        << rhoM(Tmelting, Tmelting - 1000, 0) << endl;

    // Activate auto-writing of additional fields
    if (writeAllFields_)
    {
        // nu_ is defined in incompressibleTwoPhaseMixture
        nu_.writeOpt() = IOobject::AUTO_WRITE;
        divPhi_.writeOpt() = IOobject::AUTO_WRITE;
    }
}


// * * * * * * * * * * * * * Private Member Functions  * * * * * * * * * * * //

Foam::scalar Foam::incompressibleGasMetalMixture::dSigmaDT(scalar T) const
{
    // Function1 does not support derivatives; therefore, we compute them manually
    const scalar dT = ROOTSMALL;

    return (sigmaPtr_->value(T+dT) - sigmaPtr_->value(T-dT))/2/dT;
}


Foam::tmp<Foam::volScalarField> Foam::incompressibleGasMetalMixture::dSigmaDT() const
{
    return generateGeometricField<volScalarField>
    (
        "dSigmaDT",
        T().mesh(),
        dimEnergy/dimArea/dimTemperature,
        [this](scalar T)
        {
            return dSigmaDT(T);
        },
        T()
    );
}


Foam::scalar Foam::incompressibleGasMetalMixture::rhoM(scalar Tm, scalar T, scalar phi) const
{
    scalar beta = thermo().betaLiquid().value();
    return rho1_.value() - (1 - phi)*rhoJump_ + rho1_.value()*phi*beta*(T - Tm);
}

Foam::scalar Foam::incompressibleGasMetalMixture::patchsFlowRate() const
{
	scalar totalFlux = 0;
	forAll(phi_.mesh().boundary(), patchID)
	{
		if (isA<wallFvPatch>(phi_.mesh().boundary()[patchID]))
		{ totalFlux += gSum(rhoM_.boundaryField()[patchID]
				      *alphaM_.boundaryField()[patchID]
				      *phi_.boundaryField()[patchID]);
		}
	}

	return totalFlux;
}

void Foam::incompressibleGasMetalMixture::updateRhoM()
{
    const scalar Tm = thermo().Tmelting().value();

    updateGeometricField<volScalarField>
    (
        rhoM_, [this, Tm](scalar& f, scalar T, scalar phi)
        {
            f = rhoM(Tm, T, phi);
        },
        T(), liquidFractionInMetal()
    );
}


// * * * * * * * * * * * * * * * Member Functions  * * * * * * * * * * * * * //
Foam::tmp<Foam::surfaceScalarField>  Foam::incompressibleGasMetalMixture::surfaceTensionForce()
{
    if (evaporationConsidered_) {
	const scalar dumpExpOrder = 2;
	const scalar dumpInterval = 100;

	const surfaceScalarField excedBoilTempf = fvc::interpolate(T(), "interpolate(T)") - thermo_.Tboiling();
	const dimensionedScalar dumpTempInterval("dumpTempInterva", dimTemperature, dumpInterval);
	const dimensionedScalar dumpConst = -dumpExpOrder/dumpTempInterval;

	const surfaceScalarField boilMask =
		    neg(excedBoilTempf) + pos0(excedBoilTempf)*exp(dumpConst*excedBoilTempf);
	return boilMask*(surfForcesPtr_->surfaceTensionForce());
	}
    
    return surfForcesPtr_->surfaceTensionForce();
}


Foam::tmp<Foam::volVectorField> Foam::incompressibleGasMetalMixture::marangoniForce() const
{
    const volVectorField normal(fvc::reconstruct(surfForcesPtr_->nHatf()));
    const volTensorField I_nn(tensor::I - sqr(normal));

    const volVectorField& gradAlphaM = gasMetalThermalProperties::gradAlphaM();
    const volVectorField& gradT = gasMetalThermalProperties::gradT();
    const volScalarField boilMeltMask = neg(T() - thermo_.Tboiling())*pos(T() - thermo_.Tmelting());

    // This is an alternative formula:
    //  gradT = TPrimeEnthalpy()*fvc::grad(h_) + TPrimeMetalFraction()*gradAlphaM;

    return boilMeltMask*dSigmaDT()*(gradT & I_nn)*mag(gradAlphaM);
}


Foam::tmp<Foam::volScalarField> Foam::incompressibleGasMetalMixture::solidPhaseDamping() const
{
    return mushyCoeff_*alphaM_
        *sqr(alphaM_ - liquidFraction())/(sqr(liquidFraction()) + qMushyCoeff_);
}


Foam::tmp<Foam::volScalarField> Foam::incompressibleGasMetalMixture::vapourPressure
(
    const dimensionedScalar& p0
) const
{
    using constant::physicoChemical::R;
    if (evaporationConsidered_) {
    return
        p0*exp(thermo_.metalM()*thermo_.Hvapour()/R
       *(1/thermo_.Tboiling() - 1/min(T(), Tcritical_)));
    } else {
    return 0*p0*T()/Tcritical_;
    }
}

Foam::tmp<Foam::surfaceScalarField>  Foam::incompressibleGasMetalMixture::momentumRedistributor(volScalarField& rho) const {

    Foam::tmp<Foam::surfaceScalarField> redistributor = 2.0*fvc::interpolate(rho/(rhoM_ + rho2_));

    return momentumRedistribution_ ? redistributor : (redistributor*0.0 + 1.0);
}


const Foam::volScalarField& Foam::incompressibleGasMetalMixture::divPhi()
{
    if (quasiIncompressible_) {
        const dimensionedScalar rhoJump("rhoJump", dimDensity, rhoJump_);
        const dimensionedScalar rhoLiq(thermo().rhoLiquid());
        const dimensionedScalar beta(thermo().betaLiquid());

        const dimensionedScalar meshVolume("meshVolume", dimVolume, gSum(phi_.mesh().V()));
        const scalar liquidFractionPart = liquidFraction().weightedAverage(phi_.mesh().Vsc()).value();
        const scalar SMALLVOLUME = 1e-5;

        const dimensionedScalar massChange = fvc::domainIntegrate(rhoM_*alphaM_) - initialMass_;
        const dimensionedScalar rhoCorr = massChange/((liquidFractionPart + SMALLVOLUME)*meshVolume);
        const dimensionedScalar dotRhoCorr = rhoCorr/tauCorr_;

        Info << "Density correction = " << rhoCorr.value() << endl;

        divPhi_ = alphaM_*(
                    - rhoJump*fvc::DDt(phi_, liquidFractionInMetal())
                    - liquidFractionInMetal()*beta*rhoLiq*fvc::DDt(phi_, T())
                    - liquidFractionInMetal()*dotRhoCorr
                    )/rhoM_;
    }

    return divPhi_;
}


void Foam::incompressibleGasMetalMixture::correct()
{
    // incompressibleTwoPhaseMixture -> nu
    // interfaceProperties -> K = curvature, nHatf
    immiscibleIncompressibleTwoPhaseMixture::correct();
    // gasMetalThermalProperties -> hAtMelting, gradAlphaM
    gasMetalThermalProperties::correct();
    surfForcesPtr_->correct();
}


void Foam::incompressibleGasMetalMixture::correctThermo()
{
    gasMetalThermalProperties::correctThermo();
    updateRhoM();
}


// ************************************************************************* //
