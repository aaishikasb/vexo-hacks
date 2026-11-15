# Phosphor icons

Voca bundles a small subset of the official **Phosphor Icons 2.1.1** SVGs,
under their MIT license. No runtime package or network request is required.

- Upstream: https://github.com/phosphor-icons/core
- Package: `@phosphor-icons/core@2.1.1`
- Archive: https://registry.npmjs.org/@phosphor-icons/core/-/core-2.1.1.tgz
- Archive SHA-256: `313332be6190b724da24107addd781799b48bf76b13963f24501112ffe1baadd`
- Artwork: `Voca/Assets.xcassets/phosphor-*.imageset`
- License: [Phosphor-LICENSE.txt](Phosphor-LICENSE.txt)

The original SVG paths and `viewBox` are unchanged. Each SVG adds `width="24"`
and `height="24"` so native tab items use a 24pt intrinsic size. Xcode retains
vector data and renders the assets as templates, inheriting the foreground
color from the containing control. Regular is the default weight; fill assets
are included for active states.

`PhosphorIcon` provides scaled sizing and hides redundant decorative icons
from accessibility. Name icon-only buttons at the call site. Its compatibility
aliases keep existing screen semantics while loading Phosphor artwork. New
official icon names must be added to the asset catalog before being used.
