# DbBrands font

Monochrome DBMS logos as an icon font, so they work everywhere an `IconData`
does (`AppIcons.brand*`) and take the brand color like any glyph.

```sh
mkdir -p /tmp/brands && cd /tmp/brands
curl -sL https://registry.npmjs.org/simple-icons/-/simple-icons-16.36.0.tgz | tar xz && mv package simple-icons
curl -sL https://registry.npmjs.org/devicon/-/devicon-2.18.0.tgz | tar xz && mv package devicon
cd -
python3 -m venv /tmp/brands/.venv && /tmp/brands/.venv/bin/pip install fonttools
/tmp/brands/.venv/bin/python tool/brand_font/build_brand_font.py /tmp/brands/simple-icons /tmp/brands/devicon
```

To add a logo, append it to `GLYPHS` with the next codepoint, rebuild, add the
constant to `AppIcons` (the script prints them) and credit its source in
`assets/fonts/brands/LICENSE`.
