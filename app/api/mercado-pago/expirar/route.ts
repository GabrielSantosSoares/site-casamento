import { NextResponse } from "next/server";

export async function GET() {
  return NextResponse.json(
    { error: "Rotina transferida para o Supabase Cron." },
    { status: 410 },
  );
}
