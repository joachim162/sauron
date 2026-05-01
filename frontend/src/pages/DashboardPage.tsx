import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { serversApi } from "@/api";
import { useServerContext } from "@/hooks/use-server-context";
import { useAuth } from "@/hooks/use-auth";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Server,
  Globe,
  Monitor,
  Network,
  Shield,
  ArrowRight,
} from "lucide-react";

export default function DashboardPage() {
  const { user, isSuperuser } = useAuth();
  const { serverId, serverName } = useServerContext();
  const navigate = useNavigate();

  const { data: servers, isLoading } = useQuery({
    queryKey: ["servers"],
    queryFn: serversApi.list,
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Dashboard</h1>
        <p className="text-muted-foreground">
          Welcome back, {user?.name || user?.username}
          {isSuperuser && (
            <Badge variant="secondary" className="ml-2">
              Superuser
            </Badge>
          )}
        </p>
      </div>

      {/* Quick stats */}
      {serverId ? (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          <QuickAction
            icon={Globe}
            title="Zones"
            description={`Manage zones on ${serverName}`}
            onClick={() => navigate("/zones")}
          />
          <QuickAction
            icon={Monitor}
            title="Hosts"
            description="Search and manage hosts"
            onClick={() => navigate("/hosts")}
          />
          <QuickAction
            icon={Network}
            title="Networks"
            description="IP address management"
            onClick={() => navigate("/nets")}
          />
          <QuickAction
            icon={Shield}
            title="ACLs"
            description="Access control lists"
            onClick={() => navigate("/acls")}
          />
        </div>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>Select a Server</CardTitle>
            <CardDescription>
              Choose a server to start managing DNS & DHCP
            </CardDescription>
          </CardHeader>
          <CardContent>
            {isLoading ? (
              <div className="space-y-2">
                <Skeleton className="h-12 w-full" />
                <Skeleton className="h-12 w-full" />
              </div>
            ) : (
              <div className="grid gap-2 sm:grid-cols-2">
                {servers?.map((server) => (
                  <ServerCard key={server.id} server={server} />
                ))}
                {!servers?.length && (
                  <p className="text-muted-foreground col-span-2">
                    No servers configured.{" "}
                    {isSuperuser && (
                      <Button
                        variant="link"
                        className="px-0"
                        onClick={() => navigate("/servers")}
                      >
                        Create one
                      </Button>
                    )}
                  </p>
                )}
              </div>
            )}
          </CardContent>
        </Card>
      )}

      {/* News / MOTD — coming soon */}
      <Card>
        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-3">
          <CardTitle className="text-lg">News / MOTD</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground">Coming soon.</p>
        </CardContent>
      </Card>
    </div>
  );
}

function ServerCard({ server }: { server: { id: number; name: string; comment?: string } }) {
  const { setServer } = useServerContext();
  const navigate = useNavigate();

  return (
    <button
      className="flex items-center gap-3 rounded-lg border p-4 text-left transition-colors hover:bg-accent"
      onClick={() => {
        setServer(server.id, server.name);
        navigate("/zones");
      }}
    >
      <Server className="h-8 w-8 text-muted-foreground shrink-0" />
      <div className="min-w-0 flex-1">
        <div className="font-medium truncate">{server.name}</div>
        {server.comment && (
          <div className="text-sm text-muted-foreground truncate">
            {server.comment}
          </div>
        )}
      </div>
      <ArrowRight className="h-4 w-4 text-muted-foreground shrink-0" />
    </button>
  );
}

function QuickAction({
  icon: Icon,
  title,
  description,
  onClick,
}: {
  icon: React.ComponentType<{ className?: string }>;
  title: string;
  description: string;
  onClick: () => void;
}) {
  return (
    <Card
      className="cursor-pointer transition-colors hover:bg-accent"
      onClick={onClick}
    >
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium">{title}</CardTitle>
        <Icon className="h-4 w-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <p className="text-xs text-muted-foreground">{description}</p>
      </CardContent>
    </Card>
  );
}
