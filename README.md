Zig DI Container 🚀

A simple and lightweight Dependency Injection (DI) container for Zig. Manage your dependencies effortlessly and keep your code clean!

📦 Features
* Singletons: One instance throughout the app.
* Transients: New instance every time.
* Scoped Services: Manage lifetimes within scopes.
* Generics Support: Work with generic types smoothly.
* Error Handling: Gracefully handle errors when creaing/allocating services

🛠️ Installation

Add the di module to your project using zig pm.

```zig
const di = @import("di");
```

📚 Usage
Initialize the Container

Start by setting up the DI container with an allocator.

```zig
const std = @import("std");
const di = @import("di");

const Container = di.Container;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register your services here
}
```
Register Services

Choose how you want your services to behave.

Singleton

One shared instance.

```zig
try container.registerSingleton(MyService);
```
Transient

A new instance each time.

```zig
try container.registerTransient(MyService);
```
Scoped

Managed within a specific scope.

```zig
try container.registerScoped(MyService);
```
Create a Service Provider

After registering services, create a provider to resolve them.

```zig
var serviceProvider = try container.createServiceProvider();
defer serviceProvider.deinit();
```
Resolve Services

Get instances of your services when needed.

zig
const myService = try serviceProvider.resolve(MyService);
Resolving Generics

Handle generic types with ease.

```zig
const genericService = try serviceProvider.resolve(di.Generic(MyService, .{u8}));
```
Using Scopes

Manage scoped services within a controlled environment.

```zig
var scope = try serviceProvider.initScope();
defer scope.deinit();

const scopedService = try scope.resolve(MyService);
```
Unresolve Transient Services

Manually release a service if needed.

```zig
try serviceProvider.unresolve(resolvedService);
```

🎉 Example

Here's a quick example to get you started!


```zig
const std = @import("std");
const di = @import("di");

const Container = di.Container;

// Example Services
const Logger = struct {
    pub fn init() Logger {
        return Logger{};
    }

    pub fn log(self: *Logger, message: []const u8) void {
        _ = self;
        std.log.info("{s}", .{message});
    }
};

const Database = struct {
    logger: *Logger,

    pub fn init(logger: *Logger) Database {
        return Database{
            .logger = logger,
        };
    }

    pub fn persist(self: *Database) void {
        self.logger.log("Log some job");
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var container = Container.init(allocator);
    defer container.deinit();

    // Register services
    try container.registerSingleton(Logger);
    try container.registerTransient(Database);

    // Create provider
    var provider = try container.createServiceProvider();
    defer provider.deinit();

    // Resolve services
    var db = try provider.resolve(Database);

    // Use services
    db.persist();
}
```

This example sets up a simple DI container, registers a Logger as a singleton and Database as a transient service, then resolves and uses them.

📄 License

This project is MIT licensed. See the LICENSE file for details.