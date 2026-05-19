wasMelted = Foam::max(wasMelted, liquidFraction);

refinementIndicator.primitiveFieldRef() = max(alpha1 * neg0(liquidFraction), liquidFraction);

refinementIndicator.correctBoundaryConditions();
//refinementIndicator.primitiveFieldRef() =
//    max
//    (
//        mag(fvc::grad(alpha1))().primitiveField(),
//        mag(fvc::grad(liquidFraction))().primitiveField()
//    ) * pow(mesh.V(), 1.0/3.0);
//
//refinementIndicator.correctBoundaryConditions();
mixture.correctPassiveFields();

if (writeAllFields)
{
    heatConvection = fvc::div(rhoPhi, h);

    // For debug: check that heatConduction is almost equal to heatConduction2
    heatConduction = fvc::laplacian(mixture.kappaf(), T);

    #include "gradT.H"

    heatConduction2 = fvc::laplacian(rhof*kappaByRhoCp, h)
                     - fvc::laplacian(kappaByRhoCp*hDeltaRhoSolidLiquid, liquidFraction)
                     - fvc::laplacian(kappaByRhoCp*hDeltaRhoGasSolid, alpha1);
}


