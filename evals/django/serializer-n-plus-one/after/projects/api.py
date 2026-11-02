from rest_framework import permissions, serializers, viewsets
from rest_framework.decorators import action
from rest_framework.response import Response

from .models import Project


class ProjectSerializer(serializers.ModelSerializer):
    member_names = serializers.SerializerMethodField()

    class Meta:
        model = Project
        fields = "__all__"

    def get_member_names(self, obj):
        return [m.user.get_full_name() for m in obj.memberships.all()]


class ProjectViewSet(viewsets.ModelViewSet):
    serializer_class = ProjectSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_queryset(self):
        return Project.objects.filter(team=self.request.user.team)

    @action(detail=True, methods=["post"])
    def star(self, request, pk=None):
        project = self.get_object()
        project.star_count += 1
        project.save(update_fields=["star_count"])
        return Response({"stars": project.star_count})
