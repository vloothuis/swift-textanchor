# Guide

Some introduction that nobody comments on. It has two sentences! Does it?

## Configuration

Configure the package by creating a config file in the project root. The file
is read once at startup, so restart after changing it.

- Put the file in `config/app.toml`.
- Use **bold** names for *required* keys.
- [ ] Check the [schema](https://example.com/schema) first.
- [x] Done with ~~old~~ new settings.

1. First step
2. Second step

## Deployment

Deploy with the provided script. It builds, tests and uploads the release.

```bash
./deploy.sh --prod
echo done
```

> Note: deploys run at night.
> Ask the operator first.

| Name | Value |
|------|-------|
| retries | 3 |
| timeout | 30 s |

Visit <https://example.com> or www.example.com for more.
Line with a hard break  
and a backslash break\
end.

    indented code
    second line

Setext heading
==============

Text with \*escaped\* stars and &amp; an entity.
