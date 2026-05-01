import {
  createContext,
  useContext,
  useState,
  useCallback,
  useEffect,
  type ReactNode,
} from "react";

interface ServerContextValue {
  serverId: number | null;
  serverName: string | null;
  zoneId: number | null;
  zoneName: string | null;
  setServer: (id: number, name: string) => void;
  setZone: (id: number, name: string) => void;
  clearZone: () => void;
}

const ServerContext = createContext<ServerContextValue | null>(null);

export function ServerProvider({ children }: { children: ReactNode }) {
  const [serverId, setServerId] = useState<number | null>(() => {
    const saved = localStorage.getItem("sauron_server_id");
    return saved ? Number(saved) : null;
  });
  const [serverName, setServerName] = useState<string | null>(() =>
    localStorage.getItem("sauron_server_name")
  );
  const [zoneId, setZoneId] = useState<number | null>(() => {
    const saved = localStorage.getItem("sauron_zone_id");
    return saved ? Number(saved) : null;
  });
  const [zoneName, setZoneName] = useState<string | null>(() =>
    localStorage.getItem("sauron_zone_name")
  );

  useEffect(() => {
    if (serverId) localStorage.setItem("sauron_server_id", String(serverId));
    else localStorage.removeItem("sauron_server_id");
    if (serverName) localStorage.setItem("sauron_server_name", serverName);
    else localStorage.removeItem("sauron_server_name");
  }, [serverId, serverName]);

  useEffect(() => {
    if (zoneId) localStorage.setItem("sauron_zone_id", String(zoneId));
    else localStorage.removeItem("sauron_zone_id");
    if (zoneName) localStorage.setItem("sauron_zone_name", zoneName);
    else localStorage.removeItem("sauron_zone_name");
  }, [zoneId, zoneName]);

  const setServer = useCallback((id: number, name: string) => {
    setServerId(id);
    setServerName(name);
    // Clear zone when server changes
    setZoneId(null);
    setZoneName(null);
  }, []);

  const setZone = useCallback((id: number, name: string) => {
    setZoneId(id);
    setZoneName(name);
  }, []);

  const clearZone = useCallback(() => {
    setZoneId(null);
    setZoneName(null);
  }, []);

  return (
    <ServerContext.Provider
      value={{ serverId, serverName, zoneId, zoneName, setServer, setZone, clearZone }}
    >
      {children}
    </ServerContext.Provider>
  );
}

export function useServerContext() {
  const ctx = useContext(ServerContext);
  if (!ctx) throw new Error("useServerContext must be used within ServerProvider");
  return ctx;
}
