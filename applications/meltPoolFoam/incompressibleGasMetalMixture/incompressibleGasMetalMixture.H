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

Class
    Foam::incompressibleGasMetalMixture

Description
    Transport model for incompressible immiscible gas-metal mixture.

SourceFiles
    incompressibleGasMetalMixture.C

\*---------------------------------------------------------------------------*/

#ifndef incompressibleGasMetalMixture_H
#define incompressibleGasMetalMixture_H

#include "immiscibleIncompressibleTwoPhaseMixture.H"
#include "Function1.H"
#include "Polynomial.H"

#include "gasMetalThermalProperties.H"
#include "surfaceForces.H"

// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

namespace Foam
{

/*---------------------------------------------------------------------------*\
                Class incompressibleGasMetalMixture Declaration
\*---------------------------------------------------------------------------*/

class incompressibleGasMetalMixture
:
    public immiscibleIncompressibleTwoPhaseMixture,
    public gasMetalThermalProperties<incompressibleGasMetalMixture>
{
    // Private data

        // Pointers

            //- Surface tension from TwoPhase Flow of Scheufler and Roenby 2023
            autoPtr<surfaceForces> surfForcesPtr_;

            //- Surface tension as a function of temperature [J/m^2]
            autoPtr<Function1<scalar>> sigmaPtr_;

        // Constants

            //- Coefficient related to the permeability of mushy layer [kg/m^3/s]
            const dimensionedScalar mushyCoeff_;

            //- Coefficient related to the permeability of mushy layer [kg/m^3/s]
            const dimensionedScalar qMushyCoeff_;

            //- Critical temperature for metal vapour [K]
            const dimensionedScalar Tcritical_;

            //- Metal dictionary
            const dictionary metalDict_;

            //- Flag to evaluate divergence of the velocity field
            const bool quasiIncompressible_;

            //- Flag to turn on momentum redistribution
            const bool momentumRedistribution_;
            
	    //- Flag to turn off evaporation effects
            const bool evaporationConsidered_;
           
           //- Flag to enable surface temperature correction
            const bool surfTempCorrection_;

           //- Surface temperature field [K]
            volScalarField Tsurf_;

            //- Melting density change [kg/m^3]
            const scalar rhoJump_;

            //- Initial mass at system [kg]
            dimensionedScalar initialMass_;

            //- Characteristic mass correction time [s]
            const dimensionedScalar tauCorr_;


        // Fields

            //- Metal density [kg/m^3]
            volScalarField rhoM_;

            //- Divergence of the velocity field [1/s]
            volScalarField divPhi_;


    // Private Member Functions

        //- Calculates the Marangoni coefficient
        scalar dSigmaDT(scalar T) const;

        //- Returns the Marangoni coefficient [J/m^2/K]
        tmp<volScalarField> dSigmaDT() const;

        //- Calculates the metal density
        scalar rhoM(scalar Tmelting, scalar T, scalar liquidFraction) const;

	//- Calcualte flow rate in the domain
	scalar patchsFlowRate() const;

        //- Update the metal density
        void updateRhoM();

	//- Update surface temperature using laser source and conductivity
	void updateTsurf();

        //- No copy construct
        incompressibleGasMetalMixture(const incompressibleGasMetalMixture&) = delete;

        //- No copy assignment
        void operator=(const incompressibleGasMetalMixture&) = delete;

public:

    //- Runtime type information
    TypeName("incompressibleGasMetalMixture");

    //- Constructor
    incompressibleGasMetalMixture
    (
        const volVectorField& U,
        const surfaceScalarField& phi
    );

    //- Destructor
    ~incompressibleGasMetalMixture() override = default;


    // Member Functions

        // Evaluation

            //- Return the surface tension force [N/m^3]
            tmp<surfaceScalarField> surfaceTensionForce();

            //- Return the thermal Marangoni force [N/m^3]
            tmp<volVectorField> marangoniForce() const;

            //- Return the solid-phase damping coefficient [N/m^3]
            tmp<volScalarField> solidPhaseDamping() const;

            //- Return the vapour pressure [Pa]
            tmp<volScalarField> vapourPressure(const dimensionedScalar& p0) const;

            tmp<surfaceScalarField> momentumRedistributor(volScalarField& rho) const;

            //- Access surface temperature (returns corrected or bulk T)
	    const volScalarField& Tsurf() const
             {
	      return Tsurf_;
             }

            //- Return the metal density [kg/m^3]
            const volScalarField& rhoM() const
            {
                return rhoM_;
            }

            //- Return the quasi-compressibility information
            bool quasiIncompressible() const
            {
                return quasiIncompressible_;
            }

            //- Calculate and return the divergence of the velocity field [1/s]
            const volScalarField& divPhi();

            //- Correct alpha-dependent fields
            void correct() override;

            //- Correct enthalpy-dependent fields
            void correctThermo() override;
};


// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

} // End namespace Foam

// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

#endif

// ************************************************************************* //
