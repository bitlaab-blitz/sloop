# How to Install

Navigate to your project directory. e.g., `cd my_awesome_project`

### Install the Nightly Version

Fetch **sloop** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-blitz/sloop/archive/refs/heads/main.zip
```

### Install the Release Version

Fetch **sloop** as external package dependency by running:

```sh
zig fetch --save \
https://github.com/bitlaab-blitz/sloop/archive/refs/tags/v0.0.0.zip
```

Make sure to edit `v0.0.0` with the latest release version.

## Import Module

Now, import **sloop** as external package module to your project by coping following code:

```zig title="build.zig"
const sloop = b.dependency("sloop", .{});
exe.root_module.addImport("sloop", sloop.module("sloop"));
lib.root_module.addImport("sloop", sloop.module("sloop"));
```

**Remarks:** You may need to link **libc** with your project executable - (e.g., `exe.linkLibC()`) if it hasn't been linked already.
