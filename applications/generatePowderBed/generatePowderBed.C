/*---------------------------------------------------------------------------*\
  =========                 |
  \\      /  F ield         | OpenFOAM: The Open Source CFD Toolbox
   \\    /   O peration     |
    \\  /    A nd           | Copyright held by original author(s)
     \\/     M anipulation  |
-------------------------------------------------------------------------------
                            | Copyright (C) 2019-2020 Oleg Rogozin
-------------------------------------------------------------------------------
License
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

Application
    generatePowderBed

Description
    Set initial conditions for alpha field, which represent the powder bed on
    a substrate. Works with dynamicRefineFvMesh.
    
    Supports multiple powder layers with configurable Z-spacing.
    Powder placement can be defined by a bounding box in XY
    (preferred) or by the legacy particle count / offset method.

\*---------------------------------------------------------------------------*/

#include "fvCFD.H"
#include "dynamicRefineFvMesh.H"
#include "cutCellIso.H"

// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

using constant::mathematical::pi;

scalarField generateBall
(
    const vectorField& points,
    const vector centre,
    const scalar radius
)
{
    return mag(points - centre) - radius;
}


tmp<volScalarField> VolumeOfFluid(const fvMesh& mesh, scalarField& f)
{
    cutCellIso cutCell(mesh, f);
    auto tres = volScalarField::New("result", mesh, dimensionedScalar());
    auto& res = tres.ref();

    forAll(res, cellI)
    {
        label cellStatus = cutCell.calcSubCell(cellI, Zero);

        if (cellStatus == -1)
        {
            res[cellI] = 1;
        }
        else if (cellStatus == 1)
        {
            res[cellI] = 0;
        }
        else if (cellStatus == 0)
        {
            if (mag(cutCell.faceArea()) != 0)
            {
                res[cellI] = max(min(cutCell.VolumeOfFluid(), 1), 0);
            }
        }
    }

    return tres;
}


// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //

int main(int argc, char *argv[])
{
    Foam::argList::addArgument("field");
    #include "setRootCase.H"
    #include "createTime.H"
    #include "createDynamicFvMesh.H"

    word alphaName = args.get<word>(1);

    Info<< "Reading field " << alphaName << endl;
    volScalarField alpha
    (
        IOobject
        (
            alphaName,
            runTime.timeName(),
            mesh,
            IOobject::MUST_READ,
            IOobject::AUTO_WRITE
        ),
        mesh
    );

    const word dictName("powderBedProperties");
    Info<< "Reading " << dictName << endl;
    IOdictionary dict
    (
        IOobject
        (
            dictName,
            runTime.constant(),
            mesh,
            IOobject::MUST_READ,
            IOobject::NO_WRITE
        )
    );

    // Dimensionless parameters of the powder distribution
    const label seed(dict.lookupOrDefault<label>("seed", 0));
    const scalar amplitudePosition(dict.lookupOrDefault<scalar>("amplitudePosition", 0));
    const scalar latticeStep(dict.lookupOrDefault<scalar>("latticeStep", 2));

    // Bed size control parameters
    // New box-driven approach (preferred)
    const vector boxMinVec(dict.lookupOrDefault<vector>("boxMin", vector::zero));
    const vector boxMaxVec(dict.lookupOrDefault<vector>("boxMax", vector::zero));
    bool useBox = dict.found("boxMin") && dict.found("boxMax");

    // Old manual approach (fallback if no box is given)
    const label nParticlesX(dict.lookupOrDefault<label>("nParticlesX", 15));
    const label nParticlesY(dict.lookupOrDefault<label>("nParticlesY", 5));
    const label xOffset(dict.lookupOrDefault<label>("xOffset", -2));
    const label yOffset(dict.lookupOrDefault<label>("yOffset", -2));

    if (useBox)
    {
        Info<< "Using bounding box: " << boxMinVec << " to " << boxMaxVec << endl;
    }
    else
    {
        Info<< "Using legacy particle count: "
            << nParticlesX << " x " << nParticlesY << " particles" << endl;
    }

    // Layer stacking parameters
    const label nLayers(dict.lookupOrDefault<label>("nLayers", 1));
    const dimensionedScalar layerSpacing
    (
        "layerSpacing",
        dimLength,
        dict.lookupOrDefault<scalar>("layerSpacing", 0.0)
    );

    // Dimensioned parameters
    const dimensionedScalar ballRadius("ballRadius", dict);
    const dimensionedScalar sigmaRadius("sigmaRadius", dict);
    const dimensionedScalar substratePosition("substratePosition", dict);

    Info<< "Generating powder bed with " << nLayers << " layer(s)" << endl;
    if (nLayers > 1)
    {
        Info<< "Layer spacing: " << layerSpacing.value() << " m" << endl;
    }

    // Auxiliary constants
    const vector substrateNormal(0, 0, 1);
    const scalar domainVolume = gSum(mesh.V());
    const boundBox& bounds = mesh.bounds();

    label prevMeshSize;
    label timeIndex = 1;

    // Read dynamic refinement settings and get the refinement indicator field name
    word refineFieldName;
    if (isA<dynamicRefineFvMesh>(mesh))
    {
        dictionary refineDict
        (
            IOdictionary
            (
                IOobject
                (
                    "dynamicMeshDict",
                    runTime.constant(),
                    mesh,
                    IOobject::MUST_READ,
                    IOobject::NO_WRITE,
                    false
                )
            ).optionalSubDict(mesh.typeName + "Coeffs")
        );
        timeIndex = refineDict.get<label>("refineInterval");
        refineFieldName = refineDict.get<word>("field");
    }

    // NB: mesh.update() works only for timeIndex > 0 && timeIndex % refineInterval == 0
    runTime.setTime(0, timeIndex);

    // Create the refinement indicator field if it does not already exist
    volScalarField* refineFieldPtr = nullptr;
    if (!refineFieldName.empty())
    {
        refineFieldPtr = mesh.getObjectPtr<volScalarField>(refineFieldName);
        if (!refineFieldPtr)
        {
            refineFieldPtr = new volScalarField
            (
                IOobject
                (
                    refineFieldName,
                    runTime.timeName(),
                    mesh,
                    IOobject::NO_READ,
                    IOobject::NO_WRITE
                ),
                mesh,
                dimensionedScalar(dimless, 0)
            );
        }
    }

    do
    {
        scalar exactVolumeFraction = 0;  // for theoretical prediction

        // --- Generate substrate
        {
            scalarField f = substratePosition.value() - (mesh.points() & substrateNormal);
            alpha = VolumeOfFluid(mesh, f);
            exactVolumeFraction = alpha.weightedAverage(mesh.Vsc()).value();
        }

        // --- Generate balls for each layer
        Random random(seed);

        for (label layer = 0; layer < nLayers; layer++)
        {
            // Calculate Z offset for this layer
            const scalar layerBaseZ = substratePosition.value()
                                    + ballRadius.value()
                                    + layer * (ballRadius.value() + layerSpacing.value());

            Info<< "Layer " << layer << " base Z = " << layerBaseZ << " m" << endl;

            // Determine lattice indices that cover the requested XY box
            label iMin, iMax, jMin, jMax;
            if (useBox)
            {
                const scalar dx = latticeStep * ballRadius.value();
                // floor/ceil ensure the box is fully covered
                iMin = floor(boxMinVec.x()/dx);
                iMax = ceil(boxMaxVec.x()/dx);
                jMin = floor(boxMinVec.y()/dx);
                jMax = ceil(boxMaxVec.y()/dx);
            }
            else
            {
                iMin = xOffset;
                iMax = xOffset + nParticlesX - 1;
                jMin = yOffset;
                jMax = yOffset + nParticlesY - 1;
            }

            for (label j = jMin; j <= jMax; j++)
            {
                for (label i = iMin; i <= iMax; i++)
                {
                    const scalar R = ballRadius.value()
                                   +sigmaRadius.value()*random.GaussNormal<scalar>();
                    const scalar X = (amplitudePosition*random.GaussNormal<scalar>()
                                    + latticeStep*i) * ballRadius.value();
                    const scalar Y = (amplitudePosition*random.GaussNormal<scalar>()
                                    + latticeStep*j) * ballRadius.value();

                    const scalar Z = layerBaseZ;

                    scalarField f = -generateBall(mesh.points(), vector(X, Y, Z), R);
                    alpha += VolumeOfFluid(mesh, f);

                    // Evaluate the volume of ball (full or cut)
                    if
                    (
                        bounds.min().x() < X && X < bounds.max().x()
                     && bounds.min().y() < Y && Y < bounds.max().y()
                    )
                    {
                        exactVolumeFraction += 4./3*pi*pow(R, 3)/domainVolume;
                    }
                }
            }
        }

        alpha.clip(0, 1);
        alpha.correctBoundaryConditions();

        // --- Update refinement indicator based on current alpha
        if (refineFieldPtr)
        {
            refineFieldPtr->primitiveFieldRef() = alpha;
        }

        // --- Analyze the result
        const scalar volumeFraction = alpha.weightedAverage(mesh.Vsc()).value();
        Info<< nl << "Volume fraction = " << volumeFraction
            << " theoretical = " << exactVolumeFraction
            << " error = " << (volumeFraction - exactVolumeFraction)/exactVolumeFraction
            << nl << endl;

        prevMeshSize = mesh.cells().size();
        mesh.update();
    }
    while (mesh.changing() && mesh.cells().size() > prevMeshSize);

    // --- Save the result
    Info<< "Writing field " << alphaName << endl;
    ISstream::defaultPrecision(18);
    runTime.setTime(0, 0);
    runTime.writeNow();

    Info<< "End" << endl;

    return 0;
}


// ************************************************************************* //
