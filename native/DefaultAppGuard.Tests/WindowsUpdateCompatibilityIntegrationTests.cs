using DefaultAppGuard.Core;
using System.Runtime.InteropServices;

namespace DefaultAppGuard.Tests;

[Trait("Category", "MainAlgorithmIntegration")]
public sealed class WindowsUpdateCompatibilityIntegrationTests
{
    [Fact]
    public void RealCom_NoAssociationIsReportedWithoutUsingRegistryEvidence()
    {
        var extension = ".dag" + Guid.NewGuid().ToString("N");
        var rawQuery = new ApplicationAssociationRegistrationQuery();

        var error = Assert.Throws<COMException>(() => rawQuery.QueryEffectiveProgId(extension));
        Assert.Equal(AssociationSnapshot.NoAssociationHResult, error.HResult);

        var snapshot = new WindowsAssociationReader().Read(extension);
        Assert.True(snapshot.PrimaryQueryCompleted);
        Assert.True(snapshot.NoAssociation);
        Assert.Equal(error.HResult, snapshot.QueryHResult);
        Assert.Null(snapshot.UserChoiceProgId);
        Assert.Null(snapshot.PackageId);
    }

    [Fact]
    public void RealCom_CatalogObservationsAgreeWithIndependentEffectiveQueries()
    {
        var rawQuery = new ApplicationAssociationRegistrationQuery();
        var reader = new WindowsAssociationReader();
        foreach (var entry in AssociationCatalog.Entries)
        {
            var snapshot = reader.Read(entry.Extension);
            Assert.True(snapshot.PrimaryQueryCompleted, entry.Extension);
            try
            {
                var expected = rawQuery.QueryEffectiveProgId(entry.Extension);
                Assert.False(snapshot.NoAssociation);
                Assert.Equal(expected, snapshot.EffectiveProgId, ignoreCase: true);
            }
            catch (COMException exception) when (
                exception.HResult == AssociationSnapshot.NoAssociationHResult)
            {
                Assert.True(snapshot.NoAssociation, entry.Extension);
                Assert.Equal(exception.HResult, snapshot.QueryHResult);
                Assert.Empty(snapshot.EffectiveProgId);
            }
        }
    }
}
