import type { ApiError } from "./types";

const API_BASE = "/api/v1";

class ApiClient {
  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    _options?: { noAuth?: boolean }
  ): Promise<T> {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };

    const res = await fetch(`${API_BASE}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
      credentials: "include",
    });

    // Don't redirect on 401 — let the auth context handle it
    if (res.status === 401) {
      const data = await res.json().catch(() => null);
      throw new ApiRequestError(
        (data as ApiError)?.error || "Unauthorized",
        401,
        (data as ApiError) || { error: "Unauthorized" }
      );
    }

    const data = await res.json();

    if (!res.ok) {
      const error = data as ApiError;
      throw new ApiRequestError(
        error.error || `Request failed: ${res.status}`,
        res.status,
        error
      );
    }

    return data as T;
  }

  get<T>(path: string) {
    return this.request<T>("GET", path);
  }

  post<T>(path: string, body?: unknown, options?: { noAuth?: boolean }) {
    return this.request<T>("POST", path, body, options);
  }

  put<T>(path: string, body?: unknown) {
    return this.request<T>("PUT", path, body);
  }

  del<T>(path: string) {
    return this.request<T>("DELETE", path);
  }
}

export class ApiRequestError extends Error {
  status: number;
  data: ApiError;

  constructor(message: string, status: number, data: ApiError) {
    super(message);
    this.name = "ApiRequestError";
    this.status = status;
    this.data = data;
  }
}

export const api = new ApiClient();
