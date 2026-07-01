/// Conditional export of the platform-default `VaultStore` factory:
/// filesystem (app documents) on io platforms, OPFS on web — the same
/// trio pattern the fleet uses everywhere native/web storage diverges.
library;

export 'vault_store_io.dart'
    if (dart.library.js_interop) 'vault_store_web.dart';
