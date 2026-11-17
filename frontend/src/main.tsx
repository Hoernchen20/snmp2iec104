import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MutationCache, QueryCache, QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter } from "react-router";
import { ApiError } from "./api/client";
import { App } from "./App";
import "./styles.css";

// A 401 anywhere means the session is gone (logout elsewhere, expiry,
// restart): back to the login form. A pending password change: re-read me.
function onApiError(qc: () => QueryClient) {
  return (error: unknown) => {
    if (!(error instanceof ApiError)) return;
    if (error.status === 401 && error.code !== "invalid_credentials") qc().setQueryData(["me"], null);
    if (error.code === "password_change_required") void qc().invalidateQueries({ queryKey: ["me"] });
  };
}

const queryClient: QueryClient = new QueryClient({
  queryCache: new QueryCache({ onError: onApiError(() => queryClient) }),
  mutationCache: new MutationCache({ onError: onApiError(() => queryClient) }),
  defaultOptions: {
    queries: {
      retry: (n, e) => !(e instanceof ApiError && e.status < 500) && n < 2,
      refetchOnWindowFocus: false,
    },
  },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);
