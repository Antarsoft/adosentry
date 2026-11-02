from django.contrib.auth.decorators import login_required
from django.db import connection
from django.shortcuts import get_object_or_404, render
from django.utils.safestring import mark_safe

from .models import Invoice


@login_required
def invoice_list(request):
    invoices = Invoice.objects.filter(account=request.user.account).order_by("-issued_on")[:100]
    return render(request, "billing/invoice_list.html", {"invoices": invoices})


@login_required
def invoice_detail(request, pk):
    invoice = get_object_or_404(Invoice, pk=pk)
    notes = mark_safe(invoice.customer_notes)
    return render(request, "billing/invoice_detail.html", {"invoice": invoice, "notes": notes})


@login_required
def invoice_search(request):
    term = request.GET.get("q", "")
    with connection.cursor() as cursor:
        cursor.execute(
            f"SELECT id, number FROM billing_invoice WHERE account_id = {request.user.account_id} AND number LIKE '%{term}%'"
        )
        rows = cursor.fetchall()
    return render(request, "billing/invoice_search.html", {"rows": rows})
