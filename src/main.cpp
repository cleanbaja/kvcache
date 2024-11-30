#include <iostream>

#include <seastar/core/app-template.hh>
#include <seastar/core/reactor.hh>

int main(int argc, char** argv) {
    seastar::app_template app;
    app.run(argc, argv, [] {
            std::cout << "kvcache: online with " << seastar::smp::count << " threads.\n";
            return seastar::make_ready_future<>();
    });
}