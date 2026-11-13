
#include "StdInc.h"
#include <ServerIdentityProvider.h>

#include <json.hpp>
#include "ServerLicensingComponent.h"

#include <ServerInstanceBase.h>
#include <ServerInstanceBaseRef.h>
#include <ResourceManager.h>
#include <HttpClient.h>
#include <StdInc.h>

#include <CoreConsole.h>

#include <GameServer.h>
#include <TcpListenManager.h>
#include <Error.h>

#include "boost/filesystem.hpp"
#include <boost/algorithm/string.hpp>

#include <cstdlib>
#include <future>
#include <regex>

static bool licenseChecked = false;
static HttpClient* httpClient;

static constexpr auto kLicenseTimeout = std::chrono::seconds(30);

static void RefuseToStart(const std::string& reason)
{
	console::PrintError("Server Auth", "%s\n", reason);
	console::PrintError("Server Auth", "Refusing to start.\n");

	fflush(nullptr);

	std::_Exit(1);
}

static InitFunction httpinitFunction([]()
{
	httpClient = new HttpClient();

	fx::ServerInstanceBase::OnServerCreate.Connect([](fx::ServerInstanceBase* instance)
	{
		if (licenseChecked)
		{
			return;
		}

		console::Printf("Server Auth", "Checking license...\n");

		auto var = instance->GetComponent<console::Context>()->GetVariableManager()->FindEntryRaw("sv_licenseKey");

		if (!var || var->GetValue().empty())
		{
			RefuseToStart("Please set sv_licenseKey in server.cfg!");
			return;
		}

		auto licenseKey = var->GetValue();
		boost::trim(licenseKey);

		// GMP license keys always start with "gmp"
		if (licenseKey.size() < 4 || !boost::iequals(licenseKey.substr(0, 3), "gmp"))
		{
			RefuseToStart("Invalid sv_licenseKey: GMP license keys start with \"gmp\".");
			return;
		}

#ifdef _WIN32
		const char* platformName = "windows";
#else
		const char* platformName = "linux";
#endif

		auto jsonData = nlohmann::json::object({ { "license", licenseKey }, { "product", "fxserver" }, { "platform", platformName } });
		auto tlm = instance->GetComponent<fx::TcpListenManager>();

		HttpRequestOptions opts;
		opts.ipv4 = true;
		opts.addErrorBody = true;
		opts.timeoutNoResponse = std::chrono::duration_cast<std::chrono::milliseconds>(kLicenseTimeout);

		auto done = std::make_shared<std::promise<void>>();
		auto verdict = done->get_future();

		httpClient->DoPostRequest(fmt::sprintf(GMP_LICENSING_EP "server/register.php?work=register"), jsonData.dump(), opts, [instance, tlm, done](bool success, const char* data, size_t length)
		{
			auto body = (data && length) ? std::string(data, length) : std::string{};

			nlohmann::json response;

			try
			{
				response = nlohmann::json::parse(body);
			}
			catch (const std::exception&)
			{
				RefuseToStart(success
					? "The GMP licensing server returned a malformed response."
					: "A connection with the GMP server could not be established!");
				return;
			}

			if (!success || !response.is_object() || response.value("status", 0) != 1)
			{
				RefuseToStart(response.is_object() ? response.value("message", "Authentication failed") : std::string{ "Authentication failed" });
				return;
			}

			auto consoleCtx = instance->GetComponent<console::Context>();
			{
				se::ScopedPrincipal principalScope(se::Principal{ "system.console" });
				consoleCtx->ExecuteSingleCommandDirect(ProgramArguments{ "sets", "sv_sessionId", response.value("session_id", "0") });
				consoleCtx->ExecuteSingleCommandDirect(ProgramArguments{ "set", "sv_secret", response.value("secret", "0") });
			}

			auto joinCode = response.value("join_code", std::string{});
			auto joinUrl = response.value("join_url", std::string{});

			if (!joinCode.empty())
			{
				se::ScopedPrincipal principalScope(se::Principal{ "system.console" });
				consoleCtx->ExecuteSingleCommandDirect(ProgramArguments{ "set", "gmp_joinCode", joinCode });
			}

			instance->GetComponent<fx::GameServer>()->ForceHeartbeat();

			console::Printf("Server Auth", "Server license key authentication succeeded!\n");
			console::Printf("Server Auth", "Session Id : %s\n", response.value("session_id", "0"));

			if (!joinCode.empty())
			{
				console::Printf("Server Auth", "Join code  : %s\n", joinCode);
			}

			if (!joinUrl.empty())
			{
				console::Printf("Server Auth", "Join URL   : %s\n", joinUrl);
			}

			licenseChecked = true;
			done->set_value();
		});

		if (verdict.wait_for(kLicenseTimeout + std::chrono::seconds(5)) != std::future_status::ready)
		{
			RefuseToStart("The GMP licensing server did not respond.");
			return;
		}
	},
	1);
});
