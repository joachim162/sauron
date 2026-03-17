# NetAddr-IP Syntax Fix
#bugfix #perl #netaddr-ip

During the initial data import, a syntax error was discovered in the `import` script.

## Issue
The script was attempting to call `NetAddr::IP` as a subroutine:
```perl
$obj = NetAddr::IP($val); # Fails with "Undefined subroutine"
```

## Solution
Modified the script to use the proper object-oriented constructor:
```perl
$obj = new NetAddr::IP($val); # Success
```

## Technical Distinction: Method vs. Subroutine
In Perl, the difference lies in how the package is accessed:
- **`NetAddr::IP->new($val)` or `new NetAddr::IP($val)`**: This is an **Object-Oriented method call**. It searches for the `new` method within the `NetAddr::IP` package and passes the class name as the first argument. This is the standard way to instantiate objects.
- **`NetAddr::IP($val)`**: This is a **Subroutine call**. It looks for a function named `IP` within the `NetAddr` package. Since `NetAddr::IP` is a class name and doesn't export a function named `IP`, Perl throws an "Undefined subroutine" error.

## Impacted Files
- `import`: Lines 694, 695, and 724 were updated.

## Knowledge for API Dev
When using `NetAddr::IP` in new REST API controllers, always ensure the `new` keyword is used to instantiate objects, as the module does not export a function-style constructor by default.

## Related
- [[Importing-Test-Data]]
- [[Sauron-Core-Integration]]
