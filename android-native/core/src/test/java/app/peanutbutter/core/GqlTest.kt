package app.peanutbutter.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GqlTest {
    @Test
    fun providerFilterOnlyInItsOwnCatalogQuery() {
        // Servers before 0.3.10 reject an unknown filter field, so the plain query never sends it.
        assertFalse(Gql.CATALOG.contains("\$service"))
        assertTrue(Gql.CATALOG_BY_SERVICE.contains("\$service: String"))
        assertTrue(Gql.CATALOG_BY_SERVICE.contains("service: \$service }"))
    }
}
