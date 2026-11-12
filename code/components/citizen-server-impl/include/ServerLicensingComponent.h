#pragma once

class ServerLicensingComponent : public fwRefCountable
{
public:
	ServerLicensingComponent(const std::string& key, const std::string& nucleusToken, const std::string& listingToken)
	{
		m_key = key;
		m_nucleusToken = nucleusToken;
		m_listingToken = listingToken;
	}

	inline std::string GetLicenseKey()
	{
		return m_key;
	}

	inline std::string GetNucleusToken()
	{
		return m_nucleusToken;
	}

	inline std::string GetListingToken()
	{
		return m_listingToken;
	}

private:
	std::string m_key;
	std::string m_nucleusToken;
	std::string m_listingToken;
};

DECLARE_INSTANCE_TYPE(ServerLicensingComponent);

// GMP license registration and server-listing API origin. Keep the trailing slash.
// Use HTTPS for production deployments.
#ifndef GMP_LICENSING_EP
#define GMP_LICENSING_EP "http://5.57.35.80:9891/"
#endif

// Kept for source compatibility with older code that referenced ATLAS_LICENSING_EP.
#define ATLAS_LICENSING_EP GMP_LICENSING_EP
#define LICENSING_EP GMP_LICENSING_EP
