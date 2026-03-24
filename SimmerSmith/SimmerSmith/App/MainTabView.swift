import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                WeekView()
            }
            .tabItem {
                Label("Week", systemImage: "calendar")
            }

            NavigationStack {
                GroceryView()
            }
            .tabItem {
                Label("Grocery", systemImage: "cart")
            }

            NavigationStack {
                RecipesView()
            }
            .tabItem {
                Label("Recipes", systemImage: "book")
            }

            NavigationStack {
                ActivityView()
            }
            .tabItem {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
