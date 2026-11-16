#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  updater_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "lanchat/updater",
      &flutter::StandardMethodCodec::GetInstance());
  updater_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "install") { result->NotImplemented(); return; }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) { result->Error("invalid", "Missing update path"); return; }
        const auto it = args->find(flutter::EncodableValue("path"));
        const auto* path = it == args->end() ? nullptr : std::get_if<std::string>(&it->second);
        if (!path) { result->Error("invalid", "Missing update path"); return; }
        const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            path->c_str(), -1, nullptr, 0);
        if (count <= 0) { result->Error("invalid", "Invalid update path"); return; }
        std::vector<wchar_t> wide(count);
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->c_str(), -1, wide.data(), count);
        std::vector<wchar_t> executable(32768);
        const DWORD length = GetModuleFileNameW(nullptr, executable.data(),
            static_cast<DWORD>(executable.size()));
        if (length == 0 || length >= executable.size()) {
          result->Error("install", "Cannot locate current application"); return;
        }
        const std::wstring current(executable.data(), length);
        const std::wstring folder = current.substr(0, current.find_last_of(L"\\/"));
        const std::wstring parameters = L"/DIR=\"" + folder + L"\"";
        SHELLEXECUTEINFOW info = {};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        info.hwnd = GetHandle();
        info.lpVerb = L"open";
        info.lpFile = wide.data();
        info.lpParameters = parameters.c_str();
        info.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&info)) {
          result->Error("install", "安装程序未启动或已取消授权，请重试"); return;
        }
        if (info.hProcess) CloseHandle(info.hProcess);
        result->Success(flutter::EncodableValue("launched"));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  updater_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
