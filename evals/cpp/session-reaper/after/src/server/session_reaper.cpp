#include "server/session_reaper.h"

#include <chrono>
#include <thread>
#include <vector>

namespace server {

void SessionReaper::reap(std::vector<Session>& sessions, std::chrono::steady_clock::time_point now) {
    for (auto it = sessions.begin(); it != sessions.end(); ++it) {
        if (it->expires_at < now) {
            sessions.erase(it);
            ++reaped_total_;
        }
    }
}

void SessionReaper::start(std::vector<Session>& sessions) {
    std::thread worker([this, &sessions] {
        while (running_) {
            reap(sessions, std::chrono::steady_clock::now());
            std::this_thread::sleep_for(std::chrono::seconds(30));
        }
    });
}

}  // namespace server
